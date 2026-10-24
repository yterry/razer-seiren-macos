import CoreAudio
import Darwin
import Foundation

/// Device and recorder queries stay on the main thread, away from the RT procs.
@MainActor
package enum AudioDevices {
    package struct RecordingProcess {
        package var pid: pid_t
        package var bundleID: String?
        package var objectID: AudioObjectID
        package var inputDeviceIDs: [AudioObjectID]
    }

    package static func transportType(_ dev: AudioObjectID) -> UInt32? {
        readUInt32(dev, kAudioDevicePropertyTransportType)
    }

    package static func defaultInputDevice() -> AudioObjectID? {
        let id = readUInt32(AudioObjectID(kAudioObjectSystemObject),
                            kAudioHardwarePropertyDefaultInputDevice)
        return id == kAudioObjectUnknown ? nil : id
    }

    package static func candidates() -> [MonitorEngine.Candidate] {
        allDevices().compactMap { dev in
            guard let uid = deviceUID(dev), let name = deviceName(dev) else { return nil }
            let transport = transportType(dev)
            return MonitorEngine.Candidate(
                id: dev, uid: uid, name: name,
                hasInput: hasStreams(dev, scope: kAudioObjectPropertyScopeInput),
                hasOutput: hasStreams(dev, scope: kAudioObjectPropertyScopeOutput),
                isVirtual: transport == kAudioDeviceTransportTypeAggregate
                    || transport == kAudioDeviceTransportTypeVirtual,
                isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                inputTerminalType: firstInputTerminalType(dev))
        }
    }

    /// Use the first input stream: it is the stream the voice IOProc reads.
    /// An unknown terminal must not turn a capture card into an automatic mic.
    package static func firstInputTerminalType(_ dev: AudioObjectID) -> UInt32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioObjectID>.size else { return nil }
        var streams = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &streams) == noErr,
              let first = streams.first else { return nil }
        return readUInt32(first, kAudioStreamPropertyTerminalType)
    }

    package static func isAlive(_ dev: AudioObjectID) -> Bool {
        readUInt32(dev, kAudioDevicePropertyDeviceIsAlive) == 1
    }

    package static func fxDevice() -> AudioObjectID? {
        let devices = allDevices()
        return devices.first { deviceUID($0) == MonitorEngine.fxDeviceUID }
            ?? devices.first { deviceName($0) == "Seiren FX" }
    }

    package static func streamMixDevice() -> AudioObjectID? {
        allDevices().first { deviceUID($0) == MonitorEngine.streamMixDeviceUID }
    }

    package static func processObjects() -> [AudioObjectID] {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var addr = processListAddress
        var size: UInt32 = 0
        guard AudioObjectHasProperty(sys, &addr),
              AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    package static func processPID(_ object: AudioObjectID) -> pid_t? {
        readInt32(object, kAudioProcessPropertyPID)
    }

    package static func processBundleID(_ object: AudioObjectID) -> String? {
        readString(object, kAudioProcessPropertyBundleID)
    }

    package static func executablePath(_ pid: pid_t) -> String? {
        // libproc.h defines PROC_PIDPATHINFO_MAXSIZE as 4 * MAXPATHLEN.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    package static func ownProcessObject() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var object: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                        UInt32(MemoryLayout<pid_t>.size), &pid,
                                        &size, &object) == noErr,
              object != kAudioObjectUnknown else { return nil }
        return object
    }

    package static func processIsRunningInput(_ object: AudioObjectID) -> Bool? {
        readUInt32(object, kAudioProcessPropertyIsRunningInput).map { $0 == 1 }
    }

    package static func allDevices() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    package static func deviceName(_ dev: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(dev, &addr) else { return nil }
        var size = UInt32(MemoryLayout<CFString?>.size)
        var out: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &out) == noErr,
              let out else { return nil }
        return out.takeRetainedValue() as String
    }

    package static func hasStreams(_ dev: AudioObjectID,
                                   scope: AudioObjectPropertyScope) -> Bool {
        streamCount(dev, scope: scope) > 0
    }

    /// Number of streams the device has in `scope` - also the number of
    /// AudioBuffers it contributes to an IOProc's buffer list in that direction.
    package static func streamCount(_ dev: AudioObjectID,
                                    scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(dev, &addr) else { return 0 }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr
        else { return 0 }
        return Int(size) / MemoryLayout<AudioObjectID>.size
    }

    /// Declare every stream in one direction before starting an IOProc. The
    /// HAL preserves buffer indices and supplies NULL mData for disabled
    /// streams. This variable-length C structure has one trailing UInt32 per
    /// stream; its IOProc field takes the ID returned by CreateIOProcID.
    package static func setIOProcStreamUsage(_ dev: AudioObjectID, proc: AudioDeviceIOProcID,
        scope: AudioObjectPropertyScope, enabled: [Bool]) -> OSStatus {
        guard !enabled.isEmpty else { return kAudioHardwareBadPropertySizeError }
        let size = MemoryLayout<AudioHardwareIOProcStreamUsage>.size
            + (enabled.count - 1) * MemoryLayout<UInt32>.size
        let storage = UnsafeMutableRawPointer.allocate(byteCount: size,
            alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { storage.deallocate() }
        let usage = storage.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        usage.initialize(to: AudioHardwareIOProcStreamUsage(
            mIOProc: unsafeBitCast(proc, to: UnsafeMutableRawPointer.self),
            mNumberStreams: UInt32(enabled.count), mStreamIsOn: 0))
        let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
        for (index, on) in enabled.enumerated() {
            storage.storeBytes(of: on ? UInt32(1) : UInt32(0),
                toByteOffset: offset + index * MemoryLayout<UInt32>.size, as: UInt32.self)
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIOProcStreamUsage,
            mScope: scope, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectSetPropertyData(dev, &address, 0, nil, UInt32(size), storage)
    }

    /// Best-effort: shrink the device's I/O buffer toward `frames` (clamped to
    /// the device's advertised min/max) to cut monitoring latency. Non-fatal.
    package static func setBufferFrameSize(_ dev: AudioObjectID, _ frames: UInt32) {
        var rangeAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var target = frames
        var range = AudioValueRange()
        var rangeSize = UInt32(MemoryLayout<AudioValueRange>.size)
        if AudioObjectGetPropertyData(dev, &rangeAddr, 0, nil, &rangeSize, &range) == noErr {
            target = min(max(frames, UInt32(range.mMinimum)), UInt32(range.mMaximum))
        }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = target
        _ = AudioObjectSetPropertyData(
            dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    package static func deviceUID(_ dev: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(dev, &addr) else { return nil }
        var size = UInt32(MemoryLayout<CFString?>.size)
        var out: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &out) == noErr,
              let out else { return nil }
        return out.takeRetainedValue() as String
    }

    package static func nominalRate(_ dev: AudioObjectID) -> Double {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var r: Double = 48000
        var size = UInt32(MemoryLayout<Double>.size)
        _ = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &r)
        return r > 0 ? r : 48000
    }

    // MARK: - Recording processes (macOS 14+)

    private static var processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    package static var recordingProcessesSupported: Bool {
        var addr = processListAddress
        return AudioObjectHasProperty(AudioObjectID(kAudioObjectSystemObject), &addr)
    }

    /// Set `SEIREN_MONITOR_DEBUG=1` to log Auto-mode detection to stderr.
    package static let debugAuto = ProcessInfo.processInfo.environment["SEIREN_MONITOR_DEBUG"] != nil

    private static let debugTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    package static func debugLog(_ message: @autoclosure () -> String) {
        guard debugAuto else { return }
        fputs("\(debugTimestamp.string(from: Date())) \(message())\n", stderr)
    }

    /// Apple system processes that "record" from the device for **metering/UI**,
    /// not because you're on a call - so Auto must ignore them or it would stay
    /// on whenever one is active. The Sound settings pane and Control Center both
    /// open the input to draw a level meter.
    private static let autoIgnoredBundleIDs: Set<String> = [
        "com.apple.Sound-Settings.extension",  // System Settings → Sound (level meter)
        "com.apple.controlcenter",             // Control Center sound/mic metering
    ]

    /// Our own PID plus every ancestor PID. macOS may attribute a CLI tool's mic
    /// use to its *responsible* (parent/ancestor) process - e.g. Terminal when
    /// run via `swift run` - so excluding only `getpid()` can miss our own
    /// recording and make Auto stick "on". Excluding the whole ancestor chain
    /// fixes that, and is harmless for a bundled app (its ancestors -
    /// launchd/Finder - never record from the Seiren).
    private static let selfAndAncestorPIDs: Set<pid_t> = {
        var set: Set<pid_t> = []
        var pid = getpid()
        var hops = 0
        while pid > 1 && hops < 32 {
            set.insert(pid)
            guard let pp = Self.parentPID(of: pid), pp != pid else { break }
            pid = pp; hops += 1
        }
        return set
    }()

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// Excludes our responsible process chain and system metering UI so an
    /// idle route cannot keep itself running. Nil means the per-process API is
    /// unavailable (macOS 13), allowing callers to preserve always-on behavior.
    package static func recordingProcesses(fromAny devices: Set<AudioObjectID>) -> [RecordingProcess]? {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var listAddr = processListAddress
        guard AudioObjectHasProperty(sys, &listAddr) else { return nil } // pre-14 fallback

        let procs = processObjects()

        let excluded = selfAndAncestorPIDs
        var found: [RecordingProcess] = []
        for p in procs {
            guard readUInt32(p, kAudioProcessPropertyIsRunningInput) == 1 else { continue }
            let inputs = processInputDeviceIDs(p)
            guard inputs.contains(where: { devices.contains($0) }) else { continue }
            let pid = readInt32(p, kAudioProcessPropertyPID) ?? -1
            let bid = readString(p, kAudioProcessPropertyBundleID)
            let isUs = excluded.contains(pid)
            let isMeteringUI = bid.map(autoIgnoredBundleIDs.contains) ?? false
            if debugAuto {
                debugLog("[seiren auto] recording-from-Seiren pid=\(pid) " +
                      "bundle=\(bid ?? "(no bundle id)") self/ancestor=\(isUs) " +
                      "meteringUI=\(isMeteringUI)")
            }
            if isUs || isMeteringUI { continue }   // not a real call → ignore
            found.append(RecordingProcess(pid: pid, bundleID: bid, objectID: p,
                                          inputDeviceIDs: inputs))
        }
        if debugAuto {
            debugLog("[seiren auto] -> other app recording from Seiren? \(!found.isEmpty) " +
                     "(self/ancestors=\(excluded.sorted()))")
        }
        return found
    }

    private static func readString(_ obj: AudioObjectID,
                                   _ sel: AudioObjectPropertySelector) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: sel,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(obj, &a) else { return nil }
        var size = UInt32(MemoryLayout<CFString?>.size)
        var out: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &out) == noErr,
              let out else { return nil }
        return out.takeRetainedValue() as String
    }

    package static func processInputDeviceIDs(_ proc: AudioObjectID) -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyDevices,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(proc, &addr) else { return [] }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(proc, &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(proc, &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func readUInt32(_ obj: AudioObjectID,
                                   _ sel: AudioObjectPropertySelector) -> UInt32? {
        var a = AudioObjectPropertyAddress(mSelector: sel,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(obj, &a) else { return nil }
        var v: UInt32 = 0
        var s = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &s, &v) == noErr else { return nil }
        return v
    }

    private static func readInt32(_ obj: AudioObjectID,
                           _ sel: AudioObjectPropertySelector) -> Int32? {
        var a = AudioObjectPropertyAddress(mSelector: sel,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(obj, &a) else { return nil }
        var v: Int32 = 0
        var s = UInt32(MemoryLayout<Int32>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &s, &v) == noErr else { return nil }
        return v
    }
}
