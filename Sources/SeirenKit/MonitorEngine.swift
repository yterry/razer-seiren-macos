import CoreAudio
import Darwin
import Foundation
import SeirenDSP

// MonitorEngine — software headphone monitoring for a Razer Seiren on macOS.
//
// Why this exists: the Seiren's hardware sidetone is a USB-Audio Class
// Feature-Unit control that macOS does not let us drive (AppleUSBAudio claims
// the audio interface exclusively, and Apple's Core Audio play-through is not
// wired to the device's hardware mix — both proven with seiren-probe). So we do
// it in software: a single full-duplex AudioDeviceIOProc on the Seiren copies
// mic input straight to the headphone output. Latency is ~one audio buffer.
//
// Real-time discipline: the IOProc (`monitorIOProc`) runs on Core Audio's
// real-time thread. It must not allocate, lock, call into the Objective-C or
// Swift runtimes, or touch any non-`Sendable`/refcounted state. It only reads
// plain C buffers and one global `Float` level. Everything else — device
// discovery, start/stop, hotplug, auto-mode polling — happens on the main thread.

/// Delegate notified (on the main actor) whenever the engine's observable state
/// changes: state, connected device name, mode, or level.
@MainActor public protocol MonitorEngineDelegate: AnyObject {
    func monitorEngineDidChange(_ engine: MonitorEngine)
}

// MARK: - Real-time globals (read by the audio thread)

// The audio thread cannot safely touch a Swift class instance, so the live
// monitor level lives in a free global. `nonisolated(unsafe)` tells the Swift 6
// concurrency checker we are taking manual responsibility for this access: it is
// a single naturally-atomic `Float` word, written from the main thread and read
// from the RT thread; a torn read at worst yields one slightly-off gain sample,
// which is inaudible and self-corrects on the next buffer. No lock is taken on
// the audio thread, which is the whole point.
nonisolated(unsafe) private var gMonitorLevel: Float = 0.7

/// The RT callback: fan input channel 0 to every output channel, scaled by the
/// global level; zero any trailing/extra output frames so we never emit stale
/// buffer contents. RT-safe: no allocation, no locks, no runtime calls.
nonisolated(unsafe) private let monitorIOProc: AudioDeviceIOProc = {
    (_, _, inData, _, outData, _, _) -> OSStatus in
    let outBL = UnsafeMutableAudioBufferListPointer(outData)
    let inBL = UnsafeMutableAudioBufferListPointer(
        UnsafeMutablePointer(mutating: inData))

    // No usable input this cycle → emit silence rather than garbage.
    guard inBL.count > 0, let srcRaw = inBL[0].mData else {
        for b in outBL { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        return noErr
    }

    let src = inBL[0]
    let srcCh = max(Int(src.mNumberChannels), 1)
    let s = srcRaw.assumingMemoryBound(to: Float.self)
    let srcFrames = Int(src.mDataByteSize) / (MemoryLayout<Float>.size * srcCh)
    let level = gMonitorLevel

    for bi in 0..<outBL.count {
        let out = outBL[bi]
        guard let dstRaw = out.mData else { continue }
        let dstCh = max(Int(out.mNumberChannels), 1)
        let d = dstRaw.assumingMemoryBound(to: Float.self)
        let dstFrames = Int(out.mDataByteSize) / (MemoryLayout<Float>.size * dstCh)
        let frames = min(srcFrames, dstFrames)

        var f = 0
        while f < frames {
            let sample = s[f * srcCh] * level   // mic = input channel 0
            var c = 0
            while c < dstCh { d[f * dstCh + c] = sample; c += 1 }
            f += 1
        }
        // Zero any output frames we didn't fill (input shorter than output).
        var z = frames
        while z < dstFrames {
            var c = 0
            while c < dstCh { d[z * dstCh + c] = 0; c += 1 }
            z += 1
        }
    }
    return noErr
}

// Mono scratch holding the mic after EQ, shared by `routeIOProc`. Allocated once
// (process lifetime) so the RT thread never allocates and there is no free race.
nonisolated(unsafe) private var gScratch: UnsafeMutablePointer<Float>?     // broadcast branch (→ SeirenFX)
nonisolated(unsafe) private var gScratchMon: UnsafeMutablePointer<Float>?  // monitor branch (→ headphones)
nonisolated(unsafe) private var gScratchCapacity: Int = 0

// Whether the live route runs at 96 kHz (→ Studio NS resamples 2:1 each way).
// Set on the main thread when NS / the sample rate is (re)applied; read on the
// RT thread (a benign torn read, like gMonitorLevel).
nonisolated(unsafe) private var gStudioRateIs96k: Int32 = 0

/// The RT callback for the *creator* path: runs on a private aggregate device
/// {Seiren, SeirenFX}. Reads the Seiren mic (aggregate input buffer 0, ch0),
/// applies the EQ in C (`seiren_dsp_process`), then fans the processed mono mic
/// to two output buffers: buffer 0 = the Seiren headphones (× monitor level, so
/// you hear yourself) and buffer 1 = SeirenFX (unity, so OBS/Zoom record the
/// processed voice). Buffer order is the aggregate's sub-device order
/// [Seiren, SeirenFX] — verified on hardware. RT-safe: no allocation, no locks,
/// no Swift-runtime calls; the only non-trivial call is the C DSP function.
nonisolated(unsafe) private let routeIOProc: AudioDeviceIOProc = {
    (_, _, inData, _, outData, _, _) -> OSStatus in
    let outBL = UnsafeMutableAudioBufferListPointer(outData)
    let inBL = UnsafeMutableAudioBufferListPointer(
        UnsafeMutablePointer(mutating: inData))

    guard inBL.count > 0, let micRaw = inBL[0].mData,
          let fxBuf = gScratch, let monBuf = gScratchMon else {
        for b in outBL { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        return noErr
    }

    let micCh = max(Int(inBL[0].mNumberChannels), 1)
    let mic = micRaw.assumingMemoryBound(to: Float.self)
    let avail = Int(inBL[0].mDataByteSize) / (MemoryLayout<Float>.size * micCh)
    let frames = min(avail, gScratchCapacity)

    // Shared front of the chain: mic channel 0 → gate (gate is zero-latency).
    var f = 0
    while f < frames { fxBuf[f] = mic[f * micCh]; f += 1 }
    seiren_dsp_gate(fxBuf, Int32(frames), 1)                 // no-op if gate off

    // Monitor branch (what you hear): EQ only, NO Studio, so it stays
    // low-latency. Independent EQ state bank 0.
    var m = 0
    while m < frames { monBuf[m] = fxBuf[m]; m += 1 }
    seiren_dsp_process_mono(monBuf, Int32(frames), 0)        // no-op if EQ off

    // Broadcast branch (what apps record via SeirenFX): Studio denoise then EQ.
    // The ~10 ms Studio latency lives here only. Independent EQ state bank 1.
    seiren_dsp_studio_process(fxBuf, Int32(frames), gStudioRateIs96k)  // no-op if Studio off
    seiren_dsp_process_mono(fxBuf, Int32(frames), 1)        // no-op if EQ off

    let level = gMonitorLevel
    for bi in 0..<outBL.count {
        let out = outBL[bi]
        guard let dstRaw = out.mData else { continue }
        let dstCh = max(Int(out.mNumberChannels), 1)
        let d = dstRaw.assumingMemoryBound(to: Float.self)
        let dstFrames = Int(out.mDataByteSize) / (MemoryLayout<Float>.size * dstCh)
        // Buffer 0 = Seiren headphones (monitor × level); buffer 1+ = SeirenFX
        // (broadcast, unity). Monitor is the low-latency signal; FX is denoised.
        let src = (bi == 0) ? monBuf : fxBuf
        let gain: Float = (bi == 0) ? level : 1.0
        let n = min(frames, dstFrames)

        var ff = 0
        while ff < n {
            let s = src[ff] * gain
            var c = 0
            while c < dstCh { d[ff * dstCh + c] = s; c += 1 }
            ff += 1
        }
        var z = n
        while z < dstFrames {
            var c = 0
            while c < dstCh { d[z * dstCh + c] = 0; c += 1 }
            z += 1
        }
    }
    return noErr
}

// MARK: - MonitorEngine

/// Software headphone monitoring for a Seiren: routes mic input to the
/// headphone output with one full-duplex Core Audio IOProc.
///
/// Modes (user intent, persisted by the app):
///  - `.off`    — not monitoring.
///  - `.always` — monitor whenever the Seiren is present. The macOS recording
///                indicator stays on the whole time (we hold the mic open).
///  - `.auto`   — monitor *only while another app is recording from the Seiren*
///                (e.g. a Zoom/Teams call). The recording indicator is then on
///                only during calls — when it would be on anyway. Uses the
///                macOS 14+ per-process audio API; on older macOS it falls back
///                to behaving like `.always`.
///
/// `state` is the *actual* state; the engine reconciles it against `mode` and
/// what hardware/other-apps are present, driven by a `kAudioHardwarePropertyDevices`
/// hotplug listener plus (in `.auto`) a low-rate poll of recording processes.
///
/// Threading: this is a `@MainActor` type. All public API and Core Audio device
/// management runs on the main thread. The only RT-thread code is the
/// free-function `monitorIOProc`, which reads only the global level.
@MainActor
public final class MonitorEngine {

    public enum Mode: String, Equatable, Sendable {
        case off, always, auto
    }

    public enum State: Equatable {
        case stopped            // mode .off
        case running            // IOProc live — you can hear yourself
        case waiting            // mode .auto, armed, no app recording from the Seiren yet
        case noDevice           // enabled but no Seiren present
        case permissionDenied   // TCC: Microphone access not granted
        case failed(Int32)      // a Core Audio call returned this OSStatus
    }

    // MARK: Observable state

    public private(set) var state: State = .stopped {
        didSet { if state != oldValue { notify() } }
    }
    public private(set) var connectedDeviceName: String?

    public private(set) var mode: Mode = .off {
        didSet { if mode != oldValue { notify() } }
    }

    /// Monitor gain, 0...1. Applied live to the RT proc and (by the app)
    /// persisted. Setting it is cheap and safe at any time.
    public var level: Float {
        get { gMonitorLevel }
        set {
            let clamped = min(max(newValue, 0), 1)
            guard clamped != gMonitorLevel else { return }
            gMonitorLevel = clamped
            notify()
        }
    }

    public weak var delegate: MonitorEngineDelegate?

    // MARK: EQ (creator path only — requires SeirenFX)

    /// Whether the parametric EQ is active. Takes effect only when routing
    /// through SeirenFX (the EQ shapes the mic that other apps record, and your
    /// headphone monitor). With no SeirenFX installed this is inert.
    public var eqEnabled: Bool { eqEngine.isEnabled }

    /// The active EQ preset (Flat / Podcast / Studio / Broadcast).
    public var eqPreset: EQPreset { eqEngine.preset }

    /// True when a SeirenFX virtual device is installed, so EQ + broadcast to
    /// other apps are available. The UI uses this to explain the EQ is inert
    /// (or prompt to install the driver) when false.
    public var fxAvailable: Bool { findFXDevice() != nil }

    /// True when the live IOProc is routing through SeirenFX (vs the direct
    /// monitor fallback). EQ and broadcast are effective only when this is true.
    public private(set) var isRoutingThroughFX = false {
        didSet { if isRoutingThroughFX != oldValue { notify() } }
    }

    public func setEQEnabled(_ on: Bool) {
        guard on != eqEngine.isEnabled else { return }
        eqEngine.setEnabled(on)
        notify()
    }

    public func setEQPreset(_ preset: EQPreset) {
        guard preset != eqEngine.preset else { return }
        eqEngine.setPreset(preset)
        notify()
    }

    // MARK: Noise suppression (creator path only — requires SeirenFX)

    /// Noise-suppression engine. Like the EQ, both modes are effective only on
    /// the SeirenFX route (see the header above); the direct-monitor fallback
    /// does no processing.
    ///  - `.gate`   — zero-latency downward gate (no model, no added latency).
    ///  - `.studio` — RNNoise neural denoiser ("Studio Denoise" in the UI),
    ///    ~10 ms latency; runs at 48 kHz natively or 96 kHz via 2:1 resampling.
    public enum NoiseSuppression: String, Equatable, Sendable {
        case off, gate, studio
    }

    public private(set) var noiseSuppression: NoiseSuppression = .off

    /// Gate open/close threshold in dBFS. Speech above this opens the gate;
    /// quiet room noise below it is muted. Conservative default.
    private let gateThresholdDB: Float = -50

    /// True when the live device rate lets RNNoise run (48 kHz native, or
    /// 96 kHz via the 2:1 resampler). At other rates Studio falls back to gate.
    public var studioAvailable: Bool {
        eqEngine.sampleRate == 48000 || eqEngine.sampleRate == 96000
    }

    public func setNoiseSuppression(_ ns: NoiseSuppression) {
        guard ns != noiseSuppression else { return }
        noiseSuppression = ns
        applyNoiseSuppression()
        notify()
    }

    /// Push the NS selection to the C gate + RNNoise at the live sample rate.
    /// Studio needs 48k/96k; at any other rate it falls back to the gate so the
    /// user still gets *some* suppression. gate and studio are mutually exclusive.
    private func applyNoiseSuppression() {
        let fs = eqEngine.sampleRate
        let studioOK = (fs == 48000 || fs == 96000)
        let wantStudio = (noiseSuppression == .studio) && studioOK
        let wantGate = (noiseSuppression == .gate) || (noiseSuppression == .studio && !studioOK)
        gStudioRateIs96k = (fs == 96000) ? 1 : 0
        seiren_dsp_set_gate(wantGate ? 1 : 0, gateThresholdDB, Float(fs))
        seiren_dsp_set_studio(wantStudio ? 1 : 0)
    }

    // MARK: Private

    private let deviceNameMatch: String
    private let preferredBufferFrames: UInt32
    private let autoPollInterval: TimeInterval
    private var deviceID: AudioObjectID?          // the matched Seiren, if present
    private var procID: AudioDeviceIOProcID?      // live IOProc, if running
    private var procDeviceID: AudioObjectID?      // device the IOProc is attached to (Seiren or aggregate)
    private var aggregateID: AudioObjectID?       // private aggregate, when routing through SeirenFX
    private var devicesListenerInstalled = false
    private var autoTimer: Timer?

    /// The EQ. Coefficients are pushed to the C DSP core; the route IOProc reads
    /// them on the RT thread. EQ only takes effect on the creator (aggregate)
    /// path — i.e. when SeirenFX is installed.
    private let eqEngine = EQEngine()

    /// `kAudioHardwarePropertyDevices` on the system object — fires on hotplug.
    private var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    /// The hardware listener is a C callback; it must be a stable block. We
    /// store it so we can remove exactly what we added on teardown.
    private var devicesListenerBlock: AudioObjectPropertyListenerBlock?

    /// - Parameters:
    ///   - deviceNameMatch: case-insensitive substring of the target device name.
    ///   - preferredBufferFrames: best-effort I/O buffer size applied when the
    ///     IOProc starts; smaller = lower monitoring latency. The HAL clamps it to
    ///     the device's allowed range, and a failure to apply is non-fatal. 128
    ///     frames ≈ 2.7 ms at 48 kHz.
    ///   - autoPollInterval: how often (seconds) `.auto` re-checks which apps are
    ///     recording. 1.5s gives near-instant call detection at negligible cost.
    public init(deviceNameMatch: String = "seiren",
                preferredBufferFrames: UInt32 = 128,
                autoPollInterval: TimeInterval = 1.5) {
        self.deviceNameMatch = deviceNameMatch.lowercased()
        self.preferredBufferFrames = preferredBufferFrames
        self.autoPollInterval = autoPollInterval
    }

    /// Fully release Core Audio resources: stop/destroy the IOProc, stop the
    /// auto poll, and remove the hotplug listener. Call before discarding the
    /// engine. Deliberately not in `deinit` (a Swift 6 nonisolated `deinit`
    /// can't touch the non-`Sendable` listener block, and this is a
    /// process-lifetime object); exists for tests and dynamic hosts.
    public func shutdown() {
        stopAutoTimer()
        teardownProc()
        deviceID = nil
        if let block = devicesListenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddress, DispatchQueue.main, block)
            devicesListenerBlock = nil
            devicesListenerInstalled = false
        }
        connectedDeviceName = nil
        state = .stopped
    }

    // MARK: - User intent

    /// Set the monitoring mode (the user's intent). Idempotent.
    public func setMode(_ newMode: Mode) {
        mode = newMode
        if newMode != .off { installDevicesListenerIfNeeded() }
        reconcile()
    }

    // MARK: - Reconciliation (actual state ⇄ desired state)

    /// Bring actual state in line with `mode` and what hardware/other-apps are
    /// present. Idempotent: safe on mode change, hotplug, or each auto poll.
    private func reconcile() {
        switch mode {
        case .off:
            stopAutoTimer()
            teardownProc()
            deviceID = nil
            connectedDeviceName = nil
            state = .stopped

        case .always:
            stopAutoTimer()
            guard let dev = findSeiren() else {
                teardownProc(); deviceID = nil; connectedDeviceName = nil
                state = .noDevice; return
            }
            deviceID = dev
            connectedDeviceName = deviceName(dev)
            ensureRunning(on: dev)

        case .auto:
            guard let dev = findSeiren() else {
                stopAutoTimer()
                teardownProc(); deviceID = nil; connectedDeviceName = nil
                state = .noDevice; return
            }
            deviceID = dev
            connectedDeviceName = deviceName(dev)
            startAutoTimer()
            pollAuto()          // evaluate immediately, don't wait a tick
        }
    }

    /// `.auto` heartbeat: monitor iff another app is recording from the Seiren.
    private func pollAuto() {
        guard mode == .auto else { return }
        guard let dev = deviceID ?? findSeiren() else {
            teardownProc(); deviceID = nil; connectedDeviceName = nil
            state = .noDevice; return
        }
        deviceID = dev
        // A "call" is any other app recording from the Seiren *or* from SeirenFX
        // (creator apps like OBS record the SeirenFX virtual device, not the
        // Seiren directly), so either should arm the route.
        var triggers: Set<AudioObjectID> = [dev]
        if let fx = findFXDevice() { triggers.insert(fx) }
        if otherProcessRecording(fromAny: triggers) {
            ensureRunning(on: dev)          // a call is active → start
        } else {
            if procID != nil { teardownProc() }   // nobody using the mic → idle
            if state != .permissionDenied, !state.isFailure { state = .waiting }
        }
    }

    /// Start the IOProc on `dev` if not already running there; set `.running`.
    private func ensureRunning(on dev: AudioObjectID) {
        if procID != nil, deviceID == dev {
            if state != .running { state = .running }
            return
        }
        if procID != nil { teardownProc() }   // running on a different device
        deviceID = dev
        startProc(on: dev)
    }

    /// Start monitoring on `seiren`. Prefers the creator path — a private
    /// aggregate {Seiren, SeirenFX} driven by `routeIOProc` (monitor + EQ +
    /// broadcast to other apps). Falls back to a direct monitor on the Seiren
    /// (no EQ/broadcast) when SeirenFX isn't installed or the aggregate fails.
    private func startProc(on seiren: AudioObjectID) {
        ensureScratch()

        // --- Creator path: route through SeirenFX -----------------------------
        if let fx = findFXDevice(), let agg = createAggregate(seiren: seiren, fx: fx) {
            setBufferFrameSize(agg, preferredBufferFrames)
            eqEngine.setSampleRate(nominalRate(agg))   // recompute coeffs at the live rate
            eqEngine.reset()
            applyNoiseSuppression()                    // gate/Studio at the live rate

            var pid: AudioDeviceIOProcID?
            let created = AudioDeviceCreateIOProcID(agg, routeIOProc, nil, &pid)
            if created == noErr, let pid {
                let started = AudioDeviceStart(agg, pid)
                if started == noErr {
                    procID = pid
                    procDeviceID = agg
                    aggregateID = agg
                    isRoutingThroughFX = true
                    state = .running
                    return
                }
                AudioDeviceDestroyIOProcID(agg, pid)
                if isProbablyPermissionError(started) {
                    AudioHardwareDestroyAggregateDevice(agg)
                    state = .permissionDenied
                    return
                }
                // Non-permission failure → drop the aggregate and try direct.
            }
            AudioHardwareDestroyAggregateDevice(agg)
        }

        // --- Fallback: direct monitor on the Seiren (no FX → no EQ/broadcast) --
        isRoutingThroughFX = false
        setBufferFrameSize(seiren, preferredBufferFrames)   // best-effort latency cut

        var pid: AudioDeviceIOProcID?
        // inClientData = nil: the proc reads only globals, so it needs no
        // context. Handing it `self` would invite touching a Swift object from
        // the RT thread — exactly what we forbid.
        let created = AudioDeviceCreateIOProcID(seiren, monitorIOProc, nil, &pid)
        guard created == noErr, let pid else {
            state = .failed(created)
            return
        }
        let started = AudioDeviceStart(seiren, pid)
        if started == noErr {
            procID = pid
            procDeviceID = seiren
            state = .running
        } else {
            AudioDeviceDestroyIOProcID(seiren, pid)
            state = isProbablyPermissionError(started)
                ? .permissionDenied : .failed(started)
        }
    }

    private func teardownProc() {
        if let dev = procDeviceID, let pid = procID {
            AudioDeviceStop(dev, pid)
            AudioDeviceDestroyIOProcID(dev, pid)
        }
        procID = nil
        procDeviceID = nil
        if let agg = aggregateID {
            AudioHardwareDestroyAggregateDevice(agg)
            aggregateID = nil
        }
        isRoutingThroughFX = false
    }

    // `kAudioHardwareIllegalOperationError` is what an input start typically
    // returns when Microphone access is denied. Treat the common denial codes
    // as permission, everything else as a real failure.
    private func isProbablyPermissionError(_ status: OSStatus) -> Bool {
        status == kAudioHardwareIllegalOperationError
            || status == kAudioHardwareUnknownPropertyError
    }

    // MARK: - Hotplug listener

    private func installDevicesListenerIfNeeded() {
        guard !devicesListenerInstalled else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.reconcile() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress, DispatchQueue.main, block)
        if status == noErr {
            devicesListenerBlock = block
            devicesListenerInstalled = true
        }
    }

    // MARK: - Auto-mode poll timer

    private func startAutoTimer() {
        guard autoTimer == nil else { return }
        autoTimer = Timer.scheduledTimer(withTimeInterval: autoPollInterval,
                                         repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollAuto() }
        }
    }

    private func stopAutoTimer() {
        autoTimer?.invalidate()
        autoTimer = nil
    }

    // MARK: - Device discovery

    /// First device whose name contains the match string and that has both an
    /// input and an output stream (so a full-duplex IOProc is meaningful).
    private func findSeiren() -> AudioObjectID? {
        for dev in allDevices() {
            guard let name = deviceName(dev),
                  name.lowercased().contains(deviceNameMatch) else { continue }
            if hasStreams(dev, scope: kAudioObjectPropertyScopeInput),
               hasStreams(dev, scope: kAudioObjectPropertyScopeOutput) {
                return dev
            }
        }
        return nil
    }

    private func allDevices() -> [AudioObjectID] {
        var addr = devicesAddress
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

    private func deviceName(_ dev: AudioObjectID) -> String? {
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

    private func hasStreams(_ dev: AudioObjectID,
                            scope: AudioObjectPropertyScope) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(dev, &addr) else { return false }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr
        else { return false }
        return size > 0
    }

    /// Best-effort: shrink the device's I/O buffer toward `frames` (clamped to
    /// the device's advertised min/max) to cut monitoring latency. Non-fatal.
    private func setBufferFrameSize(_ dev: AudioObjectID, _ frames: UInt32) {
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

    // MARK: - SeirenFX routing (creator path)

    /// Stable identity of the SeirenFX virtual device (see Driver/SeirenFX).
    private let fxDeviceUID = "SeirenFX:Device:0"
    /// UID of our private aggregate. Private + destroyed on teardown, so a fixed
    /// UID is safe (and lets us recognise a leaked one in diagnostics).
    private let aggregateUID = "com.yterry.seiren-mac.route"

    /// The SeirenFX device, if its driver is installed. Match by UID first
    /// (exact), then by name as a fallback.
    private func findFXDevice() -> AudioObjectID? {
        let devs = allDevices()
        if let byUID = devs.first(where: { deviceUID($0) == fxDeviceUID }) { return byUID }
        return devs.first(where: { deviceName($0) == "Seiren FX" })
    }

    /// Create a private aggregate {Seiren (clock master), SeirenFX} so one IOProc
    /// can read the mic and write both the headphone monitor and SeirenFX under a
    /// single clock (the aggregate drift-compensates SeirenFX). Returns the
    /// aggregate's device ID, or nil on failure.
    private func createAggregate(seiren: AudioObjectID, fx: AudioObjectID) -> AudioObjectID? {
        guard let seirenUID = deviceUID(seiren), let fxUID = deviceUID(fx) else { return nil }
        let desc: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceNameKey as String: "Seiren Voice",
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceIsStackedKey as String: 0,
            kAudioAggregateDeviceMasterSubDeviceKey as String: seirenUID,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: seirenUID],
                [kAudioSubDeviceUIDKey as String: fxUID,
                 kAudioSubDeviceDriftCompensationKey as String: 1],
            ],
        ]
        var agg: AudioObjectID = 0
        let st = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg)
        return (st == noErr && agg != 0) ? agg : nil
    }

    private func deviceUID(_ dev: AudioObjectID) -> String? {
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

    private func nominalRate(_ dev: AudioObjectID) -> Double {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var r: Double = 48000
        var size = UInt32(MemoryLayout<Double>.size)
        _ = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &r)
        return r > 0 ? r : 48000
    }

    /// Allocate the mono EQ scratch once (process lifetime), big enough for any
    /// realistic IO buffer. Never freed → the RT thread can read `gScratch`
    /// without an allocation or a free race.
    private func ensureScratch() {
        guard gScratch == nil else { return }
        let cap = 16384
        gScratch = UnsafeMutablePointer<Float>.allocate(capacity: cap)
        gScratch?.initialize(repeating: 0, count: cap)
        gScratchMon = UnsafeMutablePointer<Float>.allocate(capacity: cap)
        gScratchMon?.initialize(repeating: 0, count: cap)
        gScratchCapacity = cap
    }

    // MARK: - Auto mode: which apps are recording from the Seiren? (macOS 14+)

    private var processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    /// Set `SEIREN_MONITOR_DEBUG=1` to log Auto-mode detection to stderr.
    private let debugAuto = ProcessInfo.processInfo.environment["SEIREN_MONITOR_DEBUG"] != nil

    /// Apple system processes that "record" from the device for **metering/UI**,
    /// not because you're on a call — so Auto must ignore them or it would stay
    /// on whenever one is active. The Sound settings pane and Control Center both
    /// open the input to draw a level meter. Extend via `MonitorEngine`'s init if
    /// new ones surface.
    private let autoIgnoredBundleIDs: Set<String> = [
        "com.apple.Sound-Settings.extension",  // System Settings → Sound (level meter)
        "com.apple.controlcenter",             // Control Center sound/mic metering
    ]

    /// Our own PID plus every ancestor PID. macOS may attribute a CLI tool's mic
    /// use to its *responsible* (parent/ancestor) process — e.g. Terminal when
    /// run via `swift run` — so excluding only `getpid()` can miss our own
    /// recording and make Auto stick "on". Excluding the whole ancestor chain
    /// fixes that, and is harmless for a bundled app (its ancestors —
    /// launchd/Finder — never record from the Seiren).
    private lazy var selfAndAncestorPIDs: Set<pid_t> = {
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

    /// True if any process *other than us (or our responsible ancestors)* is
    /// currently recording from any device in `devices`. On macOS without the
    /// per-process audio API, returns `true` so `.auto` degrades to always-on
    /// rather than never starting.
    private func otherProcessRecording(fromAny devices: Set<AudioObjectID>) -> Bool {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var listAddr = processListAddress
        guard AudioObjectHasProperty(sys, &listAddr) else { return true } // pre-14 fallback

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &listAddr, 0, nil, &size) == noErr,
              size > 0 else { return false }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var procs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sys, &listAddr, 0, nil, &size, &procs) == noErr
        else { return false }

        let excluded = selfAndAncestorPIDs
        var found = false
        for p in procs {
            guard readUInt32(p, kAudioProcessPropertyIsRunningInput) == 1 else { continue }
            guard processInputDeviceIDs(p).contains(where: { devices.contains($0) }) else { continue }
            let pid = readInt32(p, kAudioProcessPropertyPID) ?? -1
            let bid = readString(p, kAudioProcessPropertyBundleID)
            let isUs = excluded.contains(pid)
            let isMeteringUI = bid.map(autoIgnoredBundleIDs.contains) ?? false
            if debugAuto {
                fputs("[seiren auto] recording-from-Seiren pid=\(pid) " +
                      "bundle=\(bid ?? "(no bundle id)") self/ancestor=\(isUs) " +
                      "meteringUI=\(isMeteringUI)\n", stderr)
            }
            if isUs || isMeteringUI { continue }   // not a real call → ignore
            found = true
            if !debugAuto { return true }   // fast path; in debug we log all first
        }
        if debugAuto {
            fputs("[seiren auto] -> other app recording from Seiren? \(found) " +
                  "(self/ancestors=\(excluded.sorted()))\n", stderr)
        }
        return found
    }

    private func readString(_ obj: AudioObjectID,
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

    private func processInputDeviceIDs(_ proc: AudioObjectID) -> [AudioObjectID] {
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

    private func readUInt32(_ obj: AudioObjectID,
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

    private func readInt32(_ obj: AudioObjectID,
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

    // MARK: - Delegate

    private func notify() { delegate?.monitorEngineDidChange(self) }
}

private extension MonitorEngine.State {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
