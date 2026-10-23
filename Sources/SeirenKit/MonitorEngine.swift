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
// Jack-less models (the V3 Mini) are input-only Core Audio devices: there is
// no headphone output, so no monitor. They are still fully served by the
// creator path - the same IOProc reads the mic and writes the processed voice
// to the Seiren FX virtual device, which is where the EQ and noise suppression
// reach OBS / Zoom / Discord. The engine detects the missing output at runtime
// (`deviceHasHeadphoneOutput`) rather than keying on a model list.
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

// How many leading output buffers belong to the source: 1 on a V3 Pro, 0 on
// a jack-less V3 Mini. A Seiren gets the monitor branch × level; other sources
// get silence. Every buffer after them is Seiren FX and gets broadcast at unity.
// Written before AudioDeviceStart, read on the RT thread. Internal
// (not private) so the RT proc can be driven with synthetic buffers in tests.
nonisolated(unsafe) var gMonitorOutBuffers: Int32 = 1
// A fallback headset can contribute outputs, but must never play its mic back.
nonisolated(unsafe) var gMonitorEnabled = true

// Route diagnostics: plain stores from the RT procs (single writer), read on
// the main thread through `MonitorEngine.routeDiagnostics`. A torn read is
// harmless - these feed a probe printout and bug reports, never control flow.
nonisolated(unsafe) private var gDiagCallbacks: Int64 = 0
nonisolated(unsafe) private var gDiagInputBuffers: Int32 = 0
nonisolated(unsafe) private var gDiagOutputBuffers: Int32 = 0
nonisolated(unsafe) private var gDiagInputPeak: Float = 0

/// The RT callback: fan input channel 0 to every output channel, scaled by the
/// global level; zero any trailing/extra output frames so we never emit stale
/// buffer contents. RT-safe: no allocation, no locks, no runtime calls.
nonisolated(unsafe) let monitorIOProc: AudioDeviceIOProc = {
    (_, _, inData, _, outData, _, _) -> OSStatus in
    let outBL = UnsafeMutableAudioBufferListPointer(outData)
    let inBL = UnsafeMutableAudioBufferListPointer(
        UnsafeMutablePointer(mutating: inData))
    gDiagCallbacks &+= 1
    gDiagInputBuffers = Int32(inBL.count)
    gDiagOutputBuffers = Int32(outBL.count)

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

    var peak = gDiagInputPeak
    var pf = 0
    while pf < srcFrames {
        let v = s[pf * srcCh]
        let a = v < 0 ? -v : v
        if a > peak { peak = a }
        pf += 1
    }
    gDiagInputPeak = peak

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
/// {source, SeirenFX}. Reads the source mic (aggregate input buffer 0, ch0),
/// applies the EQ in C (`seiren_dsp_process`), then fans the processed mono mic
/// to the output buffers: the first `gMonitorOutBuffers` belong to the source,
/// with monitoring (× level) for Seirens and silence for other mics. The rest
/// are SeirenFX (unity, so OBS/Zoom record the processed voice). Buffer order
/// is the aggregate's sub-device order [source, SeirenFX], one per stream,
/// verified on hardware, so a jack-less mic (no output streams) puts
/// SeirenFX at buffer 0. RT-safe: no allocation, no locks, no Swift-runtime
/// calls; the only non-trivial call is the C DSP function.
nonisolated(unsafe) let routeIOProc: AudioDeviceIOProc = {
    (_, _, inData, _, outData, _, _) -> OSStatus in
    let outBL = UnsafeMutableAudioBufferListPointer(outData)
    let inBL = UnsafeMutableAudioBufferListPointer(
        UnsafeMutablePointer(mutating: inData))
    gDiagCallbacks &+= 1
    gDiagInputBuffers = Int32(inBL.count)
    gDiagOutputBuffers = Int32(outBL.count)

    guard inBL.count > 0, let micRaw = inBL[0].mData,
          let fxBuf = gScratch, let monBuf = gScratchMon else {
        for b in outBL { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        return noErr
    }

    let micCh = max(Int(inBL[0].mNumberChannels), 1)
    let mic = micRaw.assumingMemoryBound(to: Float.self)
    let avail = Int(inBL[0].mDataByteSize) / (MemoryLayout<Float>.size * micCh)
    let frames = min(avail, gScratchCapacity)
    let monitorBuffers = Int(gMonitorOutBuffers)

    // Shared front of the chain: mic channel 0 → gate (gate is zero-latency).
    // The raw-input peak is tracked here, before any processing, so the probe
    // can tell "mic is silent / muted" from "gate closed".
    var peak = gDiagInputPeak
    var f = 0
    while f < frames {
        let v = mic[f * micCh]
        fxBuf[f] = v
        let a = v < 0 ? -v : v
        if a > peak { peak = a }
        f += 1
    }
    gDiagInputPeak = peak
    seiren_dsp_gate(fxBuf, Int32(frames), 1)                 // no-op if gate off

    // Monitor branch (what you hear): EQ only, NO Studio, so it stays
    // low-latency. Independent EQ state bank 0. Skipped for other mics and
    // Seirens without a headphone output.
    if gMonitorEnabled && monitorBuffers > 0 {
        var m = 0
        while m < frames { monBuf[m] = fxBuf[m]; m += 1 }
        seiren_dsp_process_mono(monBuf, Int32(frames), 0)    // no-op if EQ off
    }

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
        // Leading source buffers carry the Seiren monitor or silence; the
        // remaining buffers carry the denoised broadcast at unity.
        let isMonitor = bi < monitorBuffers
        if isMonitor && !gMonitorEnabled {
            memset(dstRaw, 0, Int(out.mDataByteSize))
            continue
        }
        let src = isMonitor ? monBuf : fxBuf
        let gain: Float = isMonitor ? level : 1.0
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

/// Routes a physical mic through FX, with headphone monitoring for Seirens.
/// Other mics are opened only while an app records from FX, in either enabled
/// mode, so the recording indicator stays off when the processed voice is idle.
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
        case running            // IOProc live: monitor and/or FX broadcast
        case waiting            // armed, no app recording from a trigger device
        case noDevice           // enabled but no eligible source
        /// A jack-less Seiren (V3 Mini) is attached but Seiren FX isn't
        /// installed: with no headphone output to monitor to and no virtual
        /// device to carry the processed mic, there is nowhere to route. Clears
        /// by itself once the driver is installed (coreaudiod's restart fires
        /// the hotplug listener).
        case needsFX
        case permissionDenied   // TCC: Microphone access not granted
        case failed(Int32)      // a Core Audio call returned this OSStatus
    }

    // MARK: Observable state

    public private(set) var state: State = .stopped {
        didSet { if state != oldValue { notify() } }
    }
    public enum InputPreference: Equatable, Sendable {
        case automatic
        case device(uid: String)
    }

    public struct InputDevice: Equatable, Sendable {
        public var uid: String
        public var name: String
        public var isSeiren: Bool
    }

    /// Other mics must stay closed while FX is idle, which requires the
    /// per-process recording API introduced in macOS 14.
    public private(set) var otherInputsSupported = false {
        didSet { if otherInputsSupported != oldValue { notify() } }
    }

    public private(set) var inputPreference: InputPreference = .automatic
    public private(set) var availableInputs: [InputDevice] = [] {
        didSet { if availableInputs != oldValue { notify() } }
    }
    public private(set) var activeSource: InputDevice? {
        didSet { if activeSource != oldValue { notify() } }
    }

    public var includeStreamMixInTriggers = false {
        didSet { if includeStreamMixInTriggers != oldValue { reconcile() } }
    }

    /// Only a Seiren with an output can be monitored. Other mics use FX without
    /// playing back into their own speakers or headphones. With no source, the
    /// default (true) preserves the headphone-equipped Seiren's controls.
    public private(set) var deviceHasHeadphoneOutput = true {
        didSet { if deviceHasHeadphoneOutput != oldValue { notify() } }
    }

    /// Live counters from the RT proc since the route last started, for
    /// `seiren-probe route` and bug reports: proves the IOProc is cycling,
    /// shows the buffer layout the aggregate handed us, and whether the mic is
    /// delivering signal at all.
    public struct RouteDiagnostics: Equatable, Sendable {
        /// IOProc invocations so far.
        public var callbacks: Int
        /// Input / output AudioBuffers per cycle (one per stream).
        public var inputBuffers: Int
        public var outputBuffers: Int
        /// Leading output buffers owned by the source (silent for other mics).
        public var monitorBuffers: Int
        /// Highest |sample| seen on the raw mic (linear, 0…1).
        public var inputPeak: Float
        /// Nominal rate of the device the proc runs on.
        public var sampleRate: Double
    }

    public var routeDiagnostics: RouteDiagnostics {
        RouteDiagnostics(callbacks: Int(gDiagCallbacks),
                         inputBuffers: Int(gDiagInputBuffers),
                         outputBuffers: Int(gDiagOutputBuffers),
                         monitorBuffers: Int(gMonitorOutBuffers),
                         inputPeak: gDiagInputPeak,
                         sampleRate: liveSampleRate)
    }

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
    public var fxAvailable: Bool { AudioDevices.fxDevice() != nil }

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
    private let fallbackEnabled: Bool
    private var selectedSource: Source?
    private var procSourceID: AudioObjectID?      // physical source of the live route
    private var procFXDeviceID: AudioObjectID?    // FX identity when the route started
    private var observedFXDeviceID: AudioObjectID?
    private var isShutdown = false
    private var procID: AudioDeviceIOProcID?      // live IOProc, if running
    private var procDeviceID: AudioObjectID?      // device the IOProc is attached to (Seiren or aggregate)
    private var aggregateID: AudioObjectID?       // private aggregate, when routing through SeirenFX
    private var liveSampleRate: Double = 0        // rate of the device the proc runs on (diagnostics)
    private var autoTimer: Timer?
    private var startFailure: StartFailure?

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
    private var defaultInputListenerBlock: AudioObjectPropertyListenerBlock?
    private var sampleRateListenerBlock: AudioObjectPropertyListenerBlock?
    private var recorderListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private var recorderAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private var sampleRateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    /// - Parameters:
    ///   - deviceNameMatch: case-insensitive substring of the target device name.
    ///   - preferredBufferFrames: best-effort I/O buffer size applied when the
    ///     IOProc starts; smaller = lower monitoring latency. The HAL clamps it to
    ///     the device's allowed range, and a failure to apply is non-fatal. 128
    ///     frames ≈ 2.7 ms at 48 kHz.
    ///   - autoPollInterval: recorder heartbeat in seconds, supplementing FX's
    ///     running-state listener for prompt call detection.
    ///   - fallbackEnabled: disable non-Seiren sources for deterministic tests
    ///     and diagnostics that must target only a name-matched microphone.
    public init(deviceNameMatch: String = "seiren",
                preferredBufferFrames: UInt32 = 128,
                autoPollInterval: TimeInterval = 1.5,
                fallbackEnabled: Bool = true) {
        self.deviceNameMatch = deviceNameMatch.lowercased()
        self.preferredBufferFrames = preferredBufferFrames
        self.autoPollInterval = autoPollInterval
        self.fallbackEnabled = fallbackEnabled
        installDevicesListenerIfNeeded()
        reconcile()
    }

    /// Fully release Core Audio resources: stop/destroy the IOProc, stop the
    /// auto poll, and remove the hotplug listener. Call before discarding the
    /// engine. Deliberately not in `deinit` (a Swift 6 nonisolated `deinit`
    /// can't touch the non-`Sendable` listener block, and this is a
    /// process-lifetime object); exists for tests and dynamic hosts.
    public func shutdown() {
        stopAutoTimer()
        teardownProc()
        isShutdown = true
        selectedSource = nil
        if let block = devicesListenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddress, DispatchQueue.main, block)
            devicesListenerBlock = nil
        }
        if let block = defaultInputListenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultInputAddress, DispatchQueue.main, block)
            defaultInputListenerBlock = nil
        }
        updateRecorderListeners(devices: [])
        activeSource = nil
        state = .stopped
    }

    // MARK: - User intent

    /// Set the monitoring mode (the user's intent). Idempotent.
    public func setMode(_ newMode: Mode) {
        isShutdown = false
        mode = newMode
        installDevicesListenerIfNeeded()
        reconcile()
    }

    public func setInputPreference(_ preference: InputPreference) {
        guard preference != inputPreference else { return }
        inputPreference = preference
        reconcile()
        notify()
    }

    // MARK: - Reconciliation (actual state ⇄ desired state)

    private func reconcile(fromPoll: Bool = false) {
        guard !isShutdown else { return }
        otherInputsSupported = AudioDevices.recordingProcessesSupported
        let candidates = AudioDevices.candidates()
        let fx = AudioDevices.fxDevice()
        let fxChanged = fx != observedFXDeviceID
        observedFXDeviceID = fx
        defer { if fxChanged { notify() } }
        let streamMix = AudioDevices.streamMixDevice()
        updateRecorderListeners(devices: Set([fx, streamMix].compactMap { $0 }))
        let inputs = candidates.filter(\.isEligible)
        availableInputs = (inputs.filter { $0.isSeiren(match: deviceNameMatch) }
            + inputs.filter { !$0.isSeiren(match: deviceNameMatch) }).map {
                InputDevice(uid: $0.uid, name: $0.name, isSeiren: $0.isSeiren(match: deviceNameMatch))
            }
        let defaultUID = AudioDevices.defaultInputDevice().flatMap { AudioDevices.deviceUID($0) }
        let source = Self.selectSource(from: candidates, preference: inputPreference,
                                       defaultInputUID: defaultUID, match: deviceNameMatch,
                                       fxInstalled: fx != nil && fallbackEnabled,
                                       otherInputsSupported: otherInputsSupported)
        selectedSource = source
        activeSource = mode == .off ? nil : source.map {
            InputDevice(uid: $0.device.uid, name: $0.device.name, isSeiren: $0.isSeiren)
        }
        deviceHasHeadphoneOutput = source.map { $0.isSeiren && $0.device.hasOutput } ?? true

        let dependsOnRecorders = mode == .auto || (mode != .off && source?.isSeiren == false)
        if dependsOnRecorders { startAutoTimer() } else { stopAutoTimer() }
        var triggers: Set<AudioObjectID> = []
        if let source, source.isSeiren { triggers.insert(source.device.id) }
        if let fx { triggers.insert(fx) }
        if includeStreamMixInTriggers, let streamMix { triggers.insert(streamMix) }
        let recording: Set<AudioObjectID>
        if dependsOnRecorders {
            // Before macOS 14 there is no per-process API; only Seirens retain
            // always-on behavior. Other inputs require positive recorder evidence.
            recording = AudioDevices.recordingProcesses(fromAny: triggers).map {
                Set($0.flatMap(\.inputDeviceIDs))
            } ?? (source?.isSeiren == true ? triggers : [])
        } else {
            recording = []
        }
        let decision = Self.runPolicy(mode: mode, source: source, fxInstalled: fx != nil,
                                      recordingDevices: recording, fxDeviceID: fx,
                                      streamMixDeviceID: streamMix,
                                      includeStreamMixInTriggers: includeStreamMixInTriggers)
        if decision == .running, let source {
            ensureRunning(on: source.device.id, fx: fx)
        } else {
            teardownProc()
            state = Self.reconciledState(decision: decision, current: state, fromPoll: fromPoll)
        }
    }

    private func pollAuto() { reconcile(fromPoll: true) }

    private func ensureRunning(on dev: AudioObjectID, fx: AudioObjectID?) {
        if procID != nil, procSourceID == dev, procFXDeviceID == fx,
           let procDeviceID, AudioDevices.isAlive(procDeviceID) {
            state = .running
            return
        }
        // Aggregate creation/destruction fires the devices listener too. Every
        // entry point must respect backoff, including those self-made events.
        guard Self.shouldRetryStart(sourceID: dev, fxDeviceID: fx, failure: startFailure,
                                    now: ProcessInfo.processInfo.systemUptime) else { return }
        teardownProc()
        procSourceID = dev
        procFXDeviceID = fx
        startProc(on: dev)
        startFailure = StartFailure.recording(result: state, sourceID: dev, fxDeviceID: fx,
                                              now: ProcessInfo.processInfo.systemUptime)
    }

    /// All sources use the aggregate for FX. Only a headphone-equipped Seiren
    /// can fall back to direct monitoring if FX is missing or fails to start.
    private func startProc(on source: AudioObjectID) {
        Self.ensureScratch()
        resetDiagnostics()
        let hasOutput = AudioDevices.hasStreams(source, scope: kAudioObjectPropertyScopeOutput)
        gMonitorEnabled = selectedSource?.isSeiren == true && hasOutput
        // One output buffer per source output stream leads the aggregate's
        // output list; a jack-less mic contributes none, so SeirenFX is first.
        gMonitorOutBuffers = hasOutput
            ? Int32(AudioDevices.streamCount(source, scope: kAudioObjectPropertyScopeOutput)) : 0

        // --- Creator path: route through SeirenFX -----------------------------
        var fxFailure: OSStatus?   // why the FX route didn't come up, if it didn't
        if let fx = procFXDeviceID {
            if let agg = createAggregate(source: source, fx: fx) {
                AudioDevices.setBufferFrameSize(agg, preferredBufferFrames)
                configureSampleRate(AudioDevices.nominalRate(agg))

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
                        installSampleRateListener(on: agg)
                        return
                    }
                    AudioDeviceDestroyIOProcID(agg, pid)
                    if isProbablyPermissionError(started) {
                        AudioHardwareDestroyAggregateDevice(agg)
                        state = .permissionDenied
                        return
                    }
                    fxFailure = started   // non-permission failure → try direct
                } else {
                    fxFailure = created
                }
                AudioHardwareDestroyAggregateDevice(agg)
            } else {
                fxFailure = kAudioHardwareUnspecifiedError
            }
        }

        // --- Fallback: direct monitor on the Seiren (no FX → no EQ/broadcast) --
        isRoutingThroughFX = false
        guard gMonitorEnabled else {
            // Nothing to monitor to: the FX route was the only route.
            state = fxFailure.map { .failed($0) } ?? .needsFX
            return
        }
        AudioDevices.setBufferFrameSize(source, preferredBufferFrames)   // best-effort latency cut
        configureSampleRate(AudioDevices.nominalRate(source))

        var pid: AudioDeviceIOProcID?
        // inClientData = nil: the proc reads only globals, so it needs no
        // context. Handing it `self` would invite touching a Swift object from
        // the RT thread — exactly what we forbid.
        let created = AudioDeviceCreateIOProcID(source, monitorIOProc, nil, &pid)
        guard created == noErr, let pid else {
            state = .failed(created)
            return
        }
        let started = AudioDeviceStart(source, pid)
        if started == noErr {
            procID = pid
            procDeviceID = source
            state = .running
            installSampleRateListener(on: source)
        } else {
            AudioDeviceDestroyIOProcID(source, pid)
            state = isProbablyPermissionError(started)
                ? .permissionDenied : .failed(started)
        }
    }

    private func teardownProc() {
        if let dev = procDeviceID, let block = sampleRateListenerBlock {
            AudioObjectRemovePropertyListenerBlock(dev, &sampleRateAddress, DispatchQueue.main, block)
            sampleRateListenerBlock = nil
        }
        if let dev = procDeviceID, let pid = procID {
            AudioDeviceStop(dev, pid)
            AudioDeviceDestroyIOProcID(dev, pid)
        }
        procID = nil
        procDeviceID = nil
        procSourceID = nil
        procFXDeviceID = nil
        if let agg = aggregateID {
            AudioHardwareDestroyAggregateDevice(agg)
            aggregateID = nil
        }
        isRoutingThroughFX = false
    }

    /// Shared by startup and live format changes; internal for DSP tests with
    /// synthetic audio. The IOProc must be stopped before resetting DSP state.
    func configureSampleRate(_ rate: Double) {
        liveSampleRate = rate
        eqEngine.setSampleRate(rate)
        eqEngine.reset()
        applyNoiseSuppression()
    }

    private func installSampleRateListener(on dev: AudioObjectID) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refreshSampleRate(on: dev) }
        }
        if AudioObjectAddPropertyListenerBlock(dev, &sampleRateAddress, DispatchQueue.main, block) == noErr {
            sampleRateListenerBlock = block
        }
        // Opening a Bluetooth mic can change its profile during AudioDeviceStart,
        // before the listener is installed. Read again to catch that transition.
        refreshSampleRate(on: dev)
    }

    private func refreshSampleRate(on dev: AudioObjectID) {
        guard procDeviceID == dev, let pid = procID else { return }
        let rate = AudioDevices.nominalRate(dev)
        guard rate != liveSampleRate else { return }
        // The DSP reset touches RT-owned delay lines, so pause the proc while
        // recomputing EQ and gate coefficients and replacing Studio's state.
        let stopped = AudioDeviceStop(dev, pid)
        let result: OSStatus
        if stopped == noErr {
            configureSampleRate(rate)
            result = AudioDeviceStart(dev, pid)
        } else {
            result = stopped
        }
        if result != noErr {
            state = isProbablyPermissionError(result) ? .permissionDenied : .failed(result)
            if let sourceID = procSourceID {
                startFailure = StartFailure.recording(result: state, sourceID: sourceID,
                                                      fxDeviceID: procFXDeviceID,
                                                      now: ProcessInfo.processInfo.systemUptime)
            }
            teardownProc()
        }
        notify()
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
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.reconcile() }
        }
        let system = AudioObjectID(kAudioObjectSystemObject)
        if devicesListenerBlock == nil,
           AudioObjectAddPropertyListenerBlock(system, &devicesAddress, DispatchQueue.main, block) == noErr {
            devicesListenerBlock = block
        }
        if defaultInputListenerBlock == nil,
           AudioObjectAddPropertyListenerBlock(system, &defaultInputAddress, DispatchQueue.main, block) == noErr {
            defaultInputListenerBlock = block
        }
    }

    private func updateRecorderListeners(devices: Set<AudioObjectID>) {
        for dev in Array(recorderListeners.keys) where !devices.contains(dev) {
            if let block = recorderListeners.removeValue(forKey: dev) {
                AudioObjectRemovePropertyListenerBlock(dev, &recorderAddress, DispatchQueue.main, block)
            }
        }
        for dev in devices where recorderListeners[dev] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in self?.pollAuto() }
            }
            if AudioObjectAddPropertyListenerBlock(dev, &recorderAddress, DispatchQueue.main, block) == noErr {
                recorderListeners[dev] = block
            }
        }
    }

    // MARK: - Auto-mode poll timer

    private func startAutoTimer() {
        guard autoTimer == nil else { return }
        let timer = Timer(timeInterval: autoPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollAuto() }
        }
        // Common modes: a default-mode timer stops while the menu is open, so
        // a call that ended during that time would keep the mic open until
        // the menu closed.
        RunLoop.main.add(timer, forMode: .common)
        autoTimer = timer
    }

    private func stopAutoTimer() {
        autoTimer?.invalidate()
        autoTimer = nil
    }

    // MARK: - Device discovery

    package struct Candidate: Equatable, Sendable {
        package var id: AudioObjectID
        package var uid: String
        package var name: String
        package var hasInput: Bool
        package var hasOutput: Bool
        package var isVirtual: Bool
        package var isBuiltIn: Bool
        package var inputTerminalType: UInt32?

        package init(id: AudioObjectID, uid: String = "", name: String,
                     hasInput: Bool, hasOutput: Bool, isVirtual: Bool = false,
                     isBuiltIn: Bool = false, inputTerminalType: UInt32? = nil) {
            self.id = id
            self.uid = uid
            self.name = name
            self.hasInput = hasInput
            self.hasOutput = hasOutput
            self.isVirtual = isVirtual
            self.isBuiltIn = isBuiltIn
            self.inputTerminalType = inputTerminalType
        }

        package var isMicrophone: Bool {
            switch inputTerminalType {
            case kAudioStreamTerminalTypeMicrophone, kAudioStreamTerminalTypeHeadsetMicrophone,
                 kAudioStreamTerminalTypeReceiverMicrophone: return true
            default: return false
            }
        }

        package var isEligible: Bool {
            hasInput && !isVirtual && uid != MonitorEngine.fxDeviceUID
                && uid != MonitorEngine.streamMixDeviceUID && uid != MonitorEngine.aggregateUID
                && uid != MixerEngine.aggregateUID
        }

        package func isSeiren(match: String) -> Bool {
            name.lowercased().contains(match.lowercased())
        }
    }

    package struct Source: Equatable, Sendable {
        package var device: Candidate
        package var isSeiren: Bool
    }

    /// Full-duplex Seirens retain headphone monitoring when several mics match.
    nonisolated package static func selectDevice(from candidates: [Candidate], match: String) -> Candidate? {
        let usable = candidates.filter { $0.isEligible && $0.isSeiren(match: match) }
        return usable.first(where: \.hasOutput) ?? usable.first
    }

    nonisolated package static func selectSource(
        from candidates: [Candidate], preference: InputPreference,
        defaultInputUID: String?, match: String, fxInstalled: Bool, otherInputsSupported: Bool
    ) -> Source? {
        let eligible = candidates.filter(\.isEligible)
        if case .device(let uid) = preference,
           let pinned = eligible.first(where: { $0.uid == uid }),
           pinned.isSeiren(match: match) || (fxInstalled && otherInputsSupported) {
            return Source(device: pinned, isSeiren: pinned.isSeiren(match: match))
        }
        if let seiren = selectDevice(from: eligible, match: match) {
            return Source(device: seiren, isSeiren: true)
        }
        guard fxInstalled && otherInputsSupported else { return nil }
        let fallback = eligible.first { $0.uid == defaultInputUID }
            ?? eligible.first(where: \.isBuiltIn) ?? eligible.first(where: \.isMicrophone)
        return fallback.map { Source(device: $0, isSeiren: false) }
    }

    struct StartFailure: Equatable {
        var sourceID: AudioObjectID
        var fxDeviceID: AudioObjectID?
        var time: TimeInterval

        /// A successful start clears the previous failure. Idle reconciliation
        /// must retain it so aggregate hotplug events cannot bypass backoff.
        static func recording(result: State, sourceID: AudioObjectID,
                              fxDeviceID: AudioObjectID?, now: TimeInterval) -> StartFailure? {
            switch result {
            case .failed, .permissionDenied:
                return StartFailure(sourceID: sourceID, fxDeviceID: fxDeviceID, time: now)
            default: return nil
            }
        }
    }

    nonisolated static func shouldRetryStart(sourceID: AudioObjectID, fxDeviceID: AudioObjectID?,
                                             failure: StartFailure?, now: TimeInterval) -> Bool {
        guard let failure, failure.sourceID == sourceID, failure.fxDeviceID == fxDeviceID else { return true }
        return now - failure.time >= 5
    }

    nonisolated static func reconciledState(decision: State, current: State, fromPoll: Bool) -> State {
        // Keep actionable errors visible after a call ends, but allow polls and
        // recorder listeners to recover a live call after the retry interval.
        fromPoll && decision == .waiting && current.isSticky ? current : decision
    }

    nonisolated static func runPolicy(
        mode: Mode, source: Source?, fxInstalled: Bool,
        recordingDevices: Set<AudioObjectID>, fxDeviceID: AudioObjectID?,
        streamMixDeviceID: AudioObjectID?, includeStreamMixInTriggers: Bool
    ) -> State {
        guard mode != .off else { return .stopped }
        guard let source else { return .noDevice }
        if source.isSeiren && !source.device.hasOutput && !fxInstalled { return .needsFX }
        if source.isSeiren && mode == .always { return .running }
        var triggers: Set<AudioObjectID> = []
        if source.isSeiren { triggers.insert(source.device.id) }
        if fxInstalled, let fxDeviceID { triggers.insert(fxDeviceID) }
        if includeStreamMixInTriggers, let streamMixDeviceID { triggers.insert(streamMixDeviceID) }
        return triggers.isDisjoint(with: recordingDevices) ? .waiting : .running
    }

    // MARK: - SeirenFX routing (creator path)

    /// Stable identity of the SeirenFX virtual device (see Driver/SeirenFX).
    nonisolated public static let fxDeviceUID = "SeirenFX:Device:0"
    nonisolated public static let streamMixDeviceUID = "SeirenFX:StreamMix"
    /// UID of our private aggregate. Private + destroyed on teardown, so a fixed
    /// UID is safe (and lets us recognise a leaked one in diagnostics).
    nonisolated public static let aggregateUID = "com.yterry.seiren-mac.route"

    /// The source supplies the clock; drift compensation keeps FX aligned with
    /// it even when the devices have different nominal sample rates.
    private func createAggregate(source: AudioObjectID, fx: AudioObjectID) -> AudioObjectID? {
        guard let sourceUID = AudioDevices.deviceUID(source), let fxUID = AudioDevices.deviceUID(fx) else { return nil }
        let desc: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: Self.aggregateUID,
            kAudioAggregateDeviceNameKey as String: "Seiren Voice",
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceIsStackedKey as String: 0,
            kAudioAggregateDeviceMasterSubDeviceKey as String: sourceUID,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: sourceUID],
                [kAudioSubDeviceUIDKey as String: fxUID,
                 kAudioSubDeviceDriftCompensationKey as String: 1],
            ],
        ]
        var agg: AudioObjectID = 0
        let st = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg)
        return (st == noErr && agg != 0) ? agg : nil
    }

    /// Zero the RT counters so `routeDiagnostics` describes the route that is
    /// about to start. Main thread, before `AudioDeviceStart`.
    private func resetDiagnostics() {
        gDiagCallbacks = 0
        gDiagInputBuffers = 0
        gDiagOutputBuffers = 0
        gDiagInputPeak = 0
    }

    /// Allocate the mono EQ scratch once (process lifetime), big enough for any
    /// realistic IO buffer. Never freed → the RT thread can read `gScratch`
    /// without an allocation or a free race. Static + internal so tests can
    /// drive the RT proc directly.
    static func ensureScratch() {
        guard gScratch == nil else { return }
        let cap = 16384
        gScratch = UnsafeMutablePointer<Float>.allocate(capacity: cap)
        gScratch?.initialize(repeating: 0, count: cap)
        gScratchMon = UnsafeMutablePointer<Float>.allocate(capacity: cap)
        gScratchMon?.initialize(repeating: 0, count: cap)
        gScratchCapacity = cap
    }

    // MARK: - Delegate

    private func notify() { delegate?.monitorEngineDidChange(self) }
}

private extension MonitorEngine.State {
    /// Keep actionable errors visible while idle. A later running decision
    /// can retry after backoff without a device change or user intervention.
    var isSticky: Bool {
        switch self {
        case .permissionDenied, .needsFX, .failed: return true
        case .stopped, .running, .waiting, .noDevice: return false
        }
    }
}
