import CoreAudio
import Foundation

// seiren-probe — read-only CoreAudio dump of a Razer Seiren's controls.
//
// We learned the V3 Pro's headphone "mic monitor / sidetone" is a USB-Audio
// Class control (a Feature-Unit volume + mute), NOT a vendor HID feature
// report. macOS surfaces UAC Feature Units as Core Audio control objects, so
// this tool enumerates every control on the device — volume, mute, and
// especially "listenback"/"play-through" controls (Core Audio's terms for
// hardware input monitoring) — so we can identify which one toggles sidetone.
//
// Run on the Mac with the Seiren plugged in:
//   swift run seiren-probe                  # read-only dump of all controls
//   swift run seiren-probe monitor on       # enable sidetone (play-through)
//   swift run seiren-probe monitor off      # disable sidetone
//   swift run seiren-probe monitor on 0.8   # enable + set monitor volume (0..1)
//   swift run seiren-probe monitor hold 0.9 # start device + enable, hold until Return
//   swift run seiren-probe monitor swmon 0.9 # software monitor (mic->headphone), hold
//   swift run seiren-probe procmon          # watch which processes record (for Auto mode)

// MARK: - helpers

func fourCC(_ v: UInt32) -> String {
    let bytes = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                 UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    let printable = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7f }
    if printable, let s = String(bytes: bytes, encoding: .ascii) {
        return "'\(s)'"
    }
    return String(format: "0x%08X", v)
}

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
    -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func has(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Bool {
    var a = a
    return AudioObjectHasProperty(obj, &a)
}

func settable(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Bool {
    var a = a
    var s: DarwinBoolean = false
    return AudioObjectIsPropertySettable(obj, &a, &s) == noErr && s.boolValue
}

func cfString(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> String? {
    var a = a
    guard AudioObjectHasProperty(obj, &a) else { return nil }
    var size = UInt32(MemoryLayout<CFString?>.size)
    var out: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &out) == noErr,
          let out = out else { return nil }
    return out.takeRetainedValue() as String
}

func uint32(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> UInt32? {
    var a = a
    guard AudioObjectHasProperty(obj, &a) else { return nil }
    var v: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr else { return nil }
    return v
}

func float32(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Float32? {
    var a = a
    guard AudioObjectHasProperty(obj, &a) else { return nil }
    var v: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr else { return nil }
    return v
}

func objectIDs(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> [AudioObjectID] {
    var a = a
    guard AudioObjectHasProperty(obj, &a) else { return [] }
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func classID(_ obj: AudioObjectID) -> UInt32 {
    uint32(obj, address(kAudioObjectPropertyClass)) ?? 0
}

func setUInt32(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ v: UInt32) -> OSStatus {
    var a = a
    var v = v
    return AudioObjectSetPropertyData(obj, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
}

func setFloat32(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ v: Float32) -> OSStatus {
    var a = a
    var v = v
    return AudioObjectSetPropertyData(obj, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
}

/// Toggle hardware sidetone via Core Audio play-through, and optionally set its level.
func applyMonitor(_ dev: AudioObjectID, on: Bool, level: Float32?) {
    print("\n-- applying monitor \(on ? "ON" : "OFF")\(level.map { ", level \($0)" } ?? "") --")

    // Master play-through enable lives on the input scope, element 0.
    let thru = address(kAudioDevicePropertyPlayThru, kAudioObjectPropertyScopeInput, 0)
    let st = setUInt32(dev, thru, on ? 1 : 0)
    print("  PlayThru(input,0) := \(on ? 1 : 0)  -> \(st == noErr ? "ok" : "ERR \(st)")")

    // Clear the play-through mute and (optionally) set play-through volume on the
    // owned 'ptru'-scope controls, without hardcoding object IDs.
    for obj in objectIDs(dev, address(kAudioObjectPropertyOwnedObjects)) {
        guard let scope = uint32(obj, address(kAudioControlPropertyScope)),
              scope == kAudioDevicePropertyScopePlayThrough else { continue }
        let cid = classID(obj)
        if cid == kAudioMuteControlClassID && on {
            let r = setUInt32(obj, address(kAudioBooleanControlPropertyValue), 0)
            print("  ptru mute ctrl \(obj) := 0  -> \(r == noErr ? "ok" : "ERR \(r)")")
        }
        if cid == kAudioVolumeControlClassID, let level = level {
            let r = setFloat32(obj, address(kAudioLevelControlPropertyScalarValue), level)
            print("  ptru vol ctrl \(obj) := \(level)  -> \(r == noErr ? "ok" : "ERR \(r)")")
        }
    }
}

/// Start the device hardware (so Core Audio play-through actually engages),
/// enable sidetone, and hold until the user presses Return. Tests whether
/// sidetone needs the device "running" — which a menu-bar app can maintain.
func startAndHold(_ dev: AudioObjectID, level: Float32) {
    print("\n-- monitor HOLD: start device + enable play-through --")
    // A NULL IOProc starts the hardware specifically for play-through.
    let started = AudioDeviceStart(dev, nil)
    print("  AudioDeviceStart(nil proc) -> \(started == noErr ? "ok" : "ERR \(started)")")
    if started != noErr {
        print("  (if this is a TCC error, grant Terminal: System Settings > Privacy > Microphone)")
    }
    applyMonitor(dev, on: true, level: level)
    _ = setUInt32(dev, address(kAudioDevicePropertyPlayThru, kAudioObjectPropertyScopeOutput, 0), 1)

    let pin = uint32(dev, address(kAudioDevicePropertyPlayThru, kAudioObjectPropertyScopeInput, 0)) ?? 99
    let pout = uint32(dev, address(kAudioDevicePropertyPlayThru, kAudioObjectPropertyScopeOutput, 0)) ?? 99
    print("  PlayThru now reads: input=\(pin) output=\(pout)  (1 = engaged)")

    print("\n>>> Speak into the mic — you should hear yourself in the headphones.")
    print(">>> Press Return to stop and exit. <<<")
    _ = readLine()

    _ = setUInt32(dev, address(kAudioDevicePropertyPlayThru, kAudioObjectPropertyScopeInput, 0), 0)
    let stopped = AudioDeviceStop(dev, nil)
    print("Stopped (\(stopped == noErr ? "ok" : "err \(stopped)")).")
}

// MARK: - software monitor (mic -> headphone via one full-duplex IOProc)

nonisolated(unsafe) var swMonLevel: Float32 = 0.9   // read by the RT IOProc

nonisolated(unsafe) let swMonProc: AudioDeviceIOProc = { (_, _, inData, _, outData, _, _) -> OSStatus in
    let inBL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    let outBL = UnsafeMutableAudioBufferListPointer(outData)
    guard inBL.count > 0, let srcPtr = inBL[0].mData else {
        for b in outBL { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        return noErr
    }
    let src = inBL[0]
    let srcCh = max(Int(src.mNumberChannels), 1)
    let s = srcPtr.assumingMemoryBound(to: Float32.self)
    let srcFrames = Int(src.mDataByteSize) / (MemoryLayout<Float32>.size * srcCh)
    let level = swMonLevel
    for bi in 0..<outBL.count {
        let out = outBL[bi]
        guard let dp = out.mData else { continue }
        let dstCh = max(Int(out.mNumberChannels), 1)
        let d = dp.assumingMemoryBound(to: Float32.self)
        let dstFrames = Int(out.mDataByteSize) / (MemoryLayout<Float32>.size * dstCh)
        let frames = min(srcFrames, dstFrames)
        var f = 0
        while f < frames {
            let sample = s[f * srcCh] * level   // mic = input channel 0, fanned to all out channels
            var c = 0
            while c < dstCh { d[f * dstCh + c] = sample; c += 1 }
            f += 1
        }
        var f2 = frames
        while f2 < dstFrames { var c = 0; while c < dstCh { d[f2 * dstCh + c] = 0; c += 1 }; f2 += 1 }
    }
    return noErr
}

func softwareMonitor(_ dev: AudioObjectID, level: Float32) {
    swMonLevel = level
    print("\n-- software monitor: routing mic -> headphone via IOProc (level \(level)) --")
    var procID: AudioDeviceIOProcID?
    let created = AudioDeviceCreateIOProcID(dev, swMonProc, nil, &procID)
    guard created == noErr, let procID = procID else {
        print("  AudioDeviceCreateIOProcID -> ERR \(created)")
        return
    }
    let started = AudioDeviceStart(dev, procID)
    print("  AudioDeviceStart -> \(started == noErr ? "ok" : "ERR \(started)")")
    if started != noErr {
        print("  (likely TCC: grant Terminal mic access — System Settings > Privacy > Microphone)")
    }
    print("\n>>> Speak — you should hear yourself (software monitor). Press Return to stop. <<<")
    _ = readLine()
    AudioDeviceStop(dev, procID)
    AudioDeviceDestroyIOProcID(dev, procID)
    print("Stopped.")
}

// MARK: - device dump

func dumpDeviceLevelControls(_ dev: AudioObjectID) {
    print("\n-- device-level control properties (input / output scope) --")
    let scopes: [(String, AudioObjectPropertyScope)] = [
        ("input", kAudioObjectPropertyScopeInput),
        ("output", kAudioObjectPropertyScopeOutput),
    ]
    // (label, selector, isFloat)
    let checks: [(String, AudioObjectPropertySelector, Bool)] = [
        ("Volume",            kAudioDevicePropertyVolumeScalar,          true),
        ("VolumeDecibels",    kAudioDevicePropertyVolumeDecibels,        true),
        ("Mute",              kAudioDevicePropertyMute,                  false),
        ("PlayThru",          kAudioDevicePropertyPlayThru,              false),
        ("PlayThruVolume",    kAudioDevicePropertyPlayThruVolumeScalar,  true),
        ("PlayThruDestination", kAudioDevicePropertyPlayThruDestination, false),
        ("SubMute",           kAudioDevicePropertySubMute,               false),
    ]
    var any = false
    for (sName, scope) in scopes {
        for element in UInt32(0)...UInt32(8) {
            for (cName, sel, isFloat) in checks {
                let a = address(sel, scope, element)
                guard has(dev, a) else { continue }
                any = true
                let value: String
                if isFloat {
                    value = float32(dev, a).map { String(format: "%.3f", $0) } ?? "?"
                } else {
                    value = uint32(dev, a).map(String.init) ?? "?"
                }
                print("  [\(sName) ch\(element)] \(cName) = \(value)  settable=\(settable(dev, a))")
            }
        }
    }
    if !any { print("  (none — controls likely live as owned control objects below)") }
}

func dumpOwnedControls(_ dev: AudioObjectID) {
    let owned = objectIDs(dev, address(kAudioObjectPropertyOwnedObjects))
    print("\n-- owned objects (\(owned.count)) — controls & streams --")
    for obj in owned {
        let cid = classID(obj)
        let cidStr = fourCC(cid)
        // streams aren't controls; skip the noisy ones but note them
        if cid == kAudioStreamClassID {
            let scope = uint32(obj, address(kAudioStreamPropertyDirection))
            print("  obj \(obj): stream \(cidStr) direction=\(scope.map(String.init) ?? "?")")
            continue
        }
        var line = "  obj \(obj): control \(cidStr)"
        if let scope = uint32(obj, address(kAudioControlPropertyScope)) { line += " scope \(fourCC(scope))" }
        if let elem = uint32(obj, address(kAudioControlPropertyElement)) { line += " elem \(elem)" }
        if let name = cfString(obj, address(kAudioObjectPropertyName)) { line += " name '\(name)'" }

        // value readouts by control kind
        if let b = uint32(obj, address(kAudioBooleanControlPropertyValue)) {
            line += "  value(bool)=\(b)"
        }
        if let s = float32(obj, address(kAudioLevelControlPropertyScalarValue)) {
            line += "  value(scalar)=\(String(format: "%.3f", s))"
        }
        if let d = float32(obj, address(kAudioLevelControlPropertyDecibelValue)) {
            line += "  value(dB)=\(String(format: "%.1f", d))"
        }
        if has(obj, address(kAudioBooleanControlPropertyValue)) {
            line += "  settable=\(settable(obj, address(kAudioBooleanControlPropertyValue)))"
        } else if has(obj, address(kAudioLevelControlPropertyScalarValue)) {
            line += "  settable=\(settable(obj, address(kAudioLevelControlPropertyScalarValue)))"
        }
        print(line)
    }
}

// MARK: - process monitor (which apps are recording — basis for Auto mode)

func intProp(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Int32? {
    var a = a
    guard AudioObjectHasProperty(obj, &a) else { return nil }
    var v: Int32 = 0
    var size = UInt32(MemoryLayout<Int32>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr else { return nil }
    return v
}

/// Input devices a process is recording from (by name), for the Auto-mode filter.
func procInputDeviceNames(_ o: AudioObjectID) -> [String] {
    let a = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyDevices,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
    return objectIDs(o, a).compactMap { cfString($0, address(kAudioObjectPropertyName)) }
}

/// Watch the system's per-process audio objects and report which processes are
/// running INPUT (recording), excluding ourselves, and WHICH input device each
/// uses. This is the signal an "Auto" monitoring mode keys on: start when
/// another app records *from the Seiren*, stop when none do. The per-device
/// detail matters because background daemons (avconferenced, the Sound-Settings
/// pane, etc.) also "record" — Auto mode must filter to the Seiren specifically.
/// Requires macOS 14+ (process audio objects).
func runProcMon() {
    setbuf(stdout, nil)   // unbuffered: live updates show immediately, even when piped
    let me = getpid()
    let listAddr = address(kAudioHardwarePropertyProcessObjectList)
    guard has(system, listAddr) else {
        print("kAudioHardwarePropertyProcessObjectList not available — needs macOS 14+.")
        return
    }
    print("Watching which processes are RECORDING (input). Start/stop a call, e.g. Zoom/")
    print("Teams/Photo Booth. We exclude our own PID (\(me)). Ctrl-C to quit.\n")

    var last = ""
    var ticks = 0
    while ticks < 600 {   // ~10 min safety cap
        let procs = objectIDs(system, listAddr)
        var others: [String] = []
        var sawSelf = false
        for p in procs {
            let running = (intProp(p, address(kAudioProcessPropertyIsRunningInput)) ?? 0) != 0
            guard running else { continue }
            let pid = intProp(p, address(kAudioProcessPropertyPID)) ?? -1
            let bid = cfString(p, address(kAudioProcessPropertyBundleID)) ?? "(unknown)"
            if pid == me { sawSelf = true; continue }
            let devs = procInputDeviceNames(p)
            let devStr = devs.isEmpty ? "?" : devs.joined(separator: ", ")
            others.append("    pid \(pid)  \(bid)  ← [\(devStr)]")
        }
        let snapshot = others.sorted().joined(separator: "\n")
        if snapshot != last {
            print("--- \(others.count) other process(es) recording" +
                  (sawSelf ? "  [+ this probe]" : "") + " ---")
            print(snapshot.isEmpty ? "    (none)" : snapshot)
            print("")
            last = snapshot
        }
        Thread.sleep(forTimeInterval: 1.0)
        ticks += 1
    }
}

// MARK: - main

let system = AudioObjectID(kAudioObjectSystemObject)

// `procmon` is system-wide (no Seiren required) — handle it before device lookup.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1].lowercased() == "procmon" {
    runProcMon()
    exit(0)
}

let devices = objectIDs(system, address(kAudioHardwarePropertyDevices))
print("Found \(devices.count) audio devices.")

let seirens = devices.filter {
    (cfString($0, address(kAudioObjectPropertyName)) ?? "").lowercased().contains("seiren")
}

if seirens.isEmpty {
    print("\nNo device whose name contains 'Seiren'. All devices:")
    for d in devices {
        print("  - \(cfString(d, address(kAudioObjectPropertyName)) ?? "??")")
    }
    print("\nPlug the Seiren in (USB), then re-run.")
    exit(1)
}

// Optional: "monitor on|off [scalarLevel]" toggles hardware play-through (sidetone).
let args = CommandLine.arguments
let setMode = args.count >= 3 && args[1].lowercased() == "monitor"
let holdMode = setMode && args[2].lowercased() == "hold"
let swMode = setMode && args[2].lowercased() == "swmon"
let turnOn = setMode && args[2].lowercased() == "on"
let level: Float32? = (setMode && args.count >= 4) ? Float32(args[3]) : nil

for dev in seirens {
    let name = cfString(dev, address(kAudioObjectPropertyName)) ?? "??"
    let uid = cfString(dev, address(kAudioDevicePropertyDeviceUID)) ?? "??"
    print("\n========================================================")
    print("Device: \(name)   (AudioObjectID \(dev))")
    print("UID: \(uid)")
    print("========================================================")
    if holdMode {
        startAndHold(dev, level: level ?? 0.9)
    } else if swMode {
        softwareMonitor(dev, level: level ?? 0.9)
    } else if setMode {
        applyMonitor(dev, on: turnOn, level: level)
    }
    dumpDeviceLevelControls(dev)
    dumpOwnedControls(dev)
}

print("""

Legend: control classes to look for —
  'vlme' volume   'mute' mute   'lsnb' listenback (sidetone!)   'talb' talkback
  'levl' level    'togl' toggle 'slct' selector  'dsrc' data source
Anything named/scoped like input monitor / listenback / play-through with
settable=true is the likely sidetone control. Paste this output back.
""")
