import CoreAudio
import Foundation
import SeirenDSP

@MainActor public protocol MixerEngineDelegate: AnyObject {
    func mixerEngineDidChange(_ engine: MixerEngine)
}

/// A private aggregate reads the processed voice from FX and non-mutating app
/// taps, and writes only to Stream Mix. All Core Audio management stays on the
/// main actor. The IOProc and its fixed storage live entirely in SeirenDSP C.
@MainActor
public final class MixerEngine {
    public enum Source: Codable, Equatable, Sendable {
        case voice, desktop, app(bundleID: String)
    }

    public struct Channel: Codable, Equatable, Sendable {
        public var source: Source
        public var name: String
        public var level: Float
        public var muted: Bool

        public init(source: Source, name: String, level: Float = 0.7, muted: Bool = false) {
            self.source = source
            self.name = name
            self.level = level
            self.muted = muted
        }

        public var gain: Float {
            let position = level.isFinite ? min(max(level, 0), 1) : 0
            return muted ? 0 : position * position
        }
    }

    public enum State: Equatable, Sendable {
        case off, idle, running, needsFX, needsDriverUpdate, unsupportedOS
        case failed(OSStatus)
    }

    public struct IndexMap: Equatable, Sendable {
        public var inputChannels: [Int: Int] = [:]
        public var ignoredInputs: [Int] = []
        public var mixOutput: Int = 0
        public var silencedOutputs: [Int] = []
    }

    public struct Tap: Equatable, Sendable {
        public var channelName: String
        /// Descriptor process count; Desktop audio lists excluded processes.
        public var processCount: Int
    }

    public struct Diagnostics: Equatable, Sendable {
        public var callbacks: UInt64 = 0
        public var inputBuffers: Int = 0
        public var outputBuffers: Int = 0
        public var indexMap = IndexMap()
        public var inputPeaks: [Float] = []
        public var channelPeaks: [Float] = []
        public var mixOutputPeak: Float = 0
        public var sampleRate: Double = 0
        public var taps: [Tap] = []
    }

    nonisolated public static let maxAppChannels = 6
    nonisolated public static let aggregateUID = "com.yterry.seiren-mac.mixer"
    nonisolated public static var defaultChannels: [Channel] {
        [.init(source: .voice, name: "Voice", level: 1),
         .init(source: .desktop, name: "Desktop audio")]
    }

    nonisolated public static func normalizedChannels(_ channels: [Channel]) -> [Channel] {
        var result = defaultChannels.map { base in
            var channel = channels.first { $0.source == base.source } ?? base
            channel.name = base.name
            return channel
        }
        var apps: Set<String> = []
        for channel in channels {
            guard case .app(let id) = channel.source, !id.isEmpty,
                  apps.count < maxAppChannels, apps.insert(id).inserted else { continue }
            result.append(channel)
        }
        return result.map {
            var channel = $0
            channel.level = channel.level.isFinite ? min(max(channel.level, 0), 1) : 0
            return channel
        }
    }

    /// Choose the innermost enclosing app that has a channel. Browser helpers
    /// fall back to their outer app, while nested apps such as Simulator can
    /// have their own channel. Nil means Desktop audio owns the process.
    nonisolated package static func owningAppBundleID(
        bundleID: String?, executablePath: String?, channelBundleIDs: Set<String>,
        bundleIdentifier: (String) -> String? = { Bundle(path: $0)?.bundleIdentifier }
    ) -> String? {
        // WebKit exposes no public responsible-app identity. A Safari channel
        // includes these services even when another host app uses WebKit audio.
        if bundleID == "com.apple.WebKit.GPU" || bundleID == "com.apple.WebKit.WebContent" {
            return channelBundleIDs.contains("com.apple.Safari") ? "com.apple.Safari" : nil
        }
        if let executablePath {
            var path = ""
            var apps: [String] = []
            for component in (executablePath as NSString).pathComponents {
                path = (path as NSString).appendingPathComponent(component)
                if component.lowercased().hasSuffix(".app") { apps.append(path) }
            }
            for app in apps.reversed() {
                if let id = bundleIdentifier(app), channelBundleIDs.contains(id) { return id }
            }
        }
        return bundleID.flatMap { channelBundleIDs.contains($0) ? $0 : nil }
    }

    nonisolated package static func channelProcesses(bundleIDs: [String],
        byApp: [String: Set<AudioObjectID>], excluding recorders: Set<AudioObjectID>
    ) -> [Set<AudioObjectID>] {
        bundleIDs.map { (byApp[$0] ?? []).subtracting(recorders) }
    }

    nonisolated package static func shouldIgnoreRecorder(bundleID: String?, appBundleID: String?) -> Bool {
        appBundleID == "com.yterry.seiren-mac" && bundleID == appBundleID
    }

    /// Browser web-app shims produce audio in the browser's processes, so a
    /// channel for the shim itself would always be silent.
    nonisolated package static func isWebAppShim(bundleID: String) -> Bool {
        if bundleID.hasPrefix("com.apple.Safari.WebApp") { return true }
        guard let separator = bundleID.range(of: ".app.") else { return false }
        let browser = String(bundleID[..<separator.lowerBound])
        return ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser",
                "org.chromium.Chromium"].contains {
            browser == $0 || browser.hasPrefix($0 + ".")
        }
    }

    nonisolated package static func runPolicy(enabled: Bool, supportedOS: Bool,
        hasFX: Bool, hasStreamMix: Bool, hasRecorders: Bool) -> State {
        guard enabled else { return .off }
        guard supportedOS else { return .unsupportedOS }
        guard hasFX else { return .needsFX }
        guard hasStreamMix else { return .needsDriverUpdate }
        return hasRecorders ? .running : .idle
    }

    public weak var delegate: MixerEngineDelegate?
    public private(set) var isEnabled = false
    public private(set) var channels = defaultChannels
    public private(set) var state: State = .off {
        didSet { if oldValue != state { notify() } }
    }

    /// Availability is useful even while the feature is off: the menu can offer
    /// installation/update before the user enables the mixer.
    public var availability: State {
        Self.runPolicy(enabled: true, supportedOS: Self.supportedOS,
                       hasFX: hardware.fxDevice() != nil,
                       hasStreamMix: hardware.streamMixOutputDevice() != nil, hasRecorders: false)
    }

    public var diagnostics: Diagnostics {
        guard let dsp else { return lastDiagnostics }
        var result = lastDiagnostics
        result.callbacks = seiren_mixer_callbacks(dsp)
        result.inputBuffers = Int(seiren_mixer_input_buffers(dsp))
        result.outputBuffers = Int(seiren_mixer_output_buffers(dsp))
        result.inputPeaks = (0..<min(result.inputBuffers, Int(SEIREN_MIXER_MAX_INPUTS))).map {
            seiren_mixer_input_peak(dsp, Int32($0))
        }
        result.channelPeaks = channels.indices.map { seiren_mixer_channel_peak(dsp, Int32($0)) }
        result.mixOutputPeak = seiren_mixer_output_peak(dsp)
        return result
    }

    package struct Snapshot: Equatable, Sendable {
        var fx: AudioObjectID
        var mix: AudioObjectID
        var rate: Double
        var appBundleIDs: [String]
        var apps: [Set<AudioObjectID>]
        var recorders: Set<AudioObjectID>
        var ownProcess: AudioObjectID
    }

    package struct StartFailure {
        var snapshot: Snapshot
        var time: TimeInterval

        static func recording(result: State, snapshot: Snapshot, now: TimeInterval) -> StartFailure? {
            guard case .failed = result else { return nil }
            return StartFailure(snapshot: snapshot, time: now)
        }
    }

    nonisolated package static func shouldRetryStart(snapshot: Snapshot, failure: StartFailure?,
                                                    now: TimeInterval) -> Bool {
        guard let failure, failure.snapshot == snapshot else { return true }
        return now - failure.time >= 5
    }

    private let runWithoutRecorder: Bool
    private let hardware: any MixerHardware
    private let clock: any EngineClock
    private var isShutdown = false
    private var timer: (any EngineTimer)?
    private var debounce: (any EngineTimer)?
    /// The device list and process list listeners, kept for the engine's life.
    private var systemListeners: [AudioHardwareListener] = []
    /// FX's sample rate and Stream Mix's running state, replaced when either device changes.
    private var deviceListeners: [AudioHardwareListener] = []
    private var fxObserved: AudioObjectID?
    private var mixObserved: AudioObjectID?
    private var snapshot: Snapshot?
    private var startFailure: StartFailure?
    private var aggregate: AudioObjectID?
    private var proc: AudioDeviceIOProcID?
    /// AudioDeviceStart succeeded, so teardown stops a running mixer.
    private var isStarted = false
    private var tapIDs: [AudioObjectID] = []
    private var owners: [AudioObjectID: String?] = [:]   // process object -> owning app
    private var dsp: OpaquePointer?
    private var lastDiagnostics = Diagnostics()

    private static var supportedOS: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    public convenience init() { self.init(runWithoutRecorder: false) }

    /// Package-only escape hatch for the probe, whose own recording is excluded
    /// by the same self/ancestor filter used by Auto mode.
    package convenience init(runWithoutRecorder: Bool) {
        self.init(runWithoutRecorder: runWithoutRecorder, hardware: CoreAudioHardware(), clock: SystemClock())
    }

    /// The same engine on the given hardware and clock. Tests pass fakes; the
    /// other initializers pass Core Audio and the system clock.
    package init(runWithoutRecorder: Bool = false, hardware: any MixerHardware, clock: any EngineClock) {
        self.runWithoutRecorder = runWithoutRecorder
        self.hardware = hardware
        self.clock = clock
        installSystemListeners()
        reconcile()
    }

    public func setEnabled(_ enabled: Bool) {
        guard !isShutdown else { return }
        let changed = enabled != isEnabled
        isEnabled = enabled
        if enabled, timer == nil {
            timer = clock.schedule(after: 1.5, repeats: true) { [weak self] in self?.reconcile() }
        } else if !enabled {
            timer?.cancel(); timer = nil
            debounce?.cancel(); debounce = nil
        }
        reconcile()
        if changed { notify() }
    }

    /// Clear start backoff and immediately reconsider the mix.
    public func retryNow() {
        startFailure = nil
        reconcile()
    }

    public func setChannels(_ channels: [Channel]) {
        let normalized = Self.normalizedChannels(channels)
        guard normalized != self.channels else { return }
        let sourcesChanged = normalized.map(\.source) != self.channels.map(\.source)
        self.channels = normalized
        if sourcesChanged {
            teardown()
            snapshot = nil
            owners.removeAll()
            reconcile()
        } else {
            publishGains()
        }
        notify()
    }

    public func setLevel(_ level: Float, for source: Source) {
        guard let index = channels.firstIndex(where: { $0.source == source }) else { return }
        var updated = channels
        updated[index].level = level
        setChannels(updated)
    }

    public func setMuted(_ muted: Bool, for source: Source) {
        guard let index = channels.firstIndex(where: { $0.source == source }) else { return }
        var updated = channels
        updated[index].muted = muted
        setChannels(updated)
    }

    public func addApp(bundleID: String, name: String) {
        setChannels(channels + [.init(source: .app(bundleID: bundleID), name: name)])
    }

    public func removeApp(bundleID: String) {
        setChannels(channels.filter { $0.source != .app(bundleID: bundleID) })
    }

    public func shutdown() {
        isShutdown = true
        timer?.cancel(); timer = nil
        debounce?.cancel(); debounce = nil
        teardown()
        for listener in systemListeners + deviceListeners { hardware.removeListener(listener) }
        systemListeners = []
        deviceListeners = []
        isEnabled = false
        state = .off
    }

    private func publishGains() {
        guard let dsp else { return }
        for (index, channel) in channels.enumerated() {
            seiren_mixer_set_gain(dsp, Int32(index), channel.gain)
        }
    }

    private func reconcile() {
        guard !isShutdown else { return }
        let fx = hardware.fxDevice(), mix = hardware.streamMixDevice()
        let mixOutput = hardware.streamMixOutputDevice()
        let devicesChanged = fx != fxObserved || mix != mixObserved
        if devicesChanged {
            updateDeviceListeners(fx: fx, mix: mix)
            fxObserved = fx; mixObserved = mix
            notify()
        }
        let recorders = (mix.map { hardware.recordingProcesses(fromAny: [$0]) ?? [] } ?? []).filter {
            !Self.shouldIgnoreRecorder(bundleID: $0.bundleID, appBundleID: Bundle.main.bundleIdentifier)
        }
        let desired = Self.runPolicy(enabled: isEnabled, supportedOS: Self.supportedOS,
            hasFX: fx != nil, hasStreamMix: mixOutput != nil,
            hasRecorders: runWithoutRecorder || !recorders.isEmpty)
        guard desired == .running, let fx, let mixOutput else {
            teardown(); snapshot = nil; state = desired
            return
        }
        guard #available(macOS 14.2, *) else { return }
        guard let ownProcess = hardware.ownProcessObject() else {
            if state != .failed(kAudioHardwareBadObjectError) {
                EventLog.shared.log(category: .mixer, message:
                    "start failed: no process object status=\(kAudioHardwareBadObjectError)")
            }
            teardown(); state = .failed(kAudioHardwareBadObjectError)
            return
        }
        let appBundleIDs = channels.compactMap { channel -> String? in
            guard case .app(let id) = channel.source else { return nil }
            return id
        }
        let channelIDs = Set(appBundleIDs)
        var byApp: [String: Set<AudioObjectID>] = [:]
        let objects = Set(hardware.processObjects())
        // Cache ownership for each process and channel list. Changing channels
        // clears this cache because a nested app may now own its own audio.
        owners = owners.filter { objects.contains($0.key) }
        for object in objects {
            let owner: String?
            if let cached = owners[object] {
                owner = cached
            } else {
                let pid = hardware.processPID(object)
                owner = Self.owningAppBundleID(bundleID: hardware.processBundleID(object),
                    executablePath: pid.flatMap { hardware.executablePath($0) },
                    channelBundleIDs: channelIDs)
                owners.updateValue(owner, forKey: object)
            }
            if let owner { byApp[owner, default: []].insert(object) }
        }
        let recorderObjects = Set(recorders.map(\.objectID))
        let appProcesses = Self.channelProcesses(bundleIDs: appBundleIDs, byApp: byApp, excluding: recorderObjects)
        let current = Snapshot(fx: fx, mix: mixOutput, rate: hardware.nominalRate(fx), appBundleIDs: appBundleIDs,
            apps: appProcesses, recorders: recorderObjects, ownProcess: ownProcess)
        // A coreaudiod restart can hand out the same IDs, so "running with the
        // same inputs" only counts while our aggregate still exists.
        if current == snapshot, state == .running, let aggregate, hardware.isAlive(aggregate) { return }
        // Creating/destroying our aggregate and taps also fires listeners. Keep
        // the failure across idle/teardown so every entry point obeys backoff.
        guard Self.shouldRetryStart(snapshot: current, failure: startFailure,
                                    now: clock.uptime) else { return }
        teardown()
        snapshot = current
        let status = start(current)
        if status == noErr {
            isStarted = true
            EventLog.shared.log(category: .mixer, message:
                "start: \(channels.count) channels, \(lastDiagnostics.taps.count) taps")
            state = .running
        } else {
            EventLog.shared.log(category: .mixer, message: "start failed: status=\(status)")
            teardown(); state = .failed(status)
        }
        startFailure = StartFailure.recording(result: state, snapshot: current,
                                              now: clock.uptime)
    }

    @available(macOS 14.2, *)
    private func start(_ current: Snapshot) -> OSStatus {
        var excluded = current.recorders.union([current.ownProcess])
        for processes in current.apps { excluded.formUnion(processes) }
        var descriptions: [(Int, MixerTap.Processes, Int)] = [
            (1, .allExcept(excluded.sorted()), excluded.count)
        ]
        for (index, processes) in current.apps.enumerated() where !processes.isEmpty {
            descriptions.append((index + 2, .only(processes.sorted()), processes.count))
        }
        var tapList: [[String: Any]] = []
        var tapDiagnostics: [Tap] = []
        for (channel, processes, count) in descriptions {
            let created = hardware.createProcessTap(
                MixerTap(processes: processes, name: "Seiren Mixer: \(channels[channel].name)"))
            guard created.status == noErr else { return created.status }
            tapIDs.append(created.id)
            tapList.append([kAudioSubTapUIDKey as String: created.uid,
                            kAudioSubTapDriftCompensationKey as String: 1])
            tapDiagnostics.append(Tap(channelName: channels[channel].name, processCount: count))
        }
        guard let fxUID = hardware.deviceUID(current.fx),
              let mixUID = hardware.deviceUID(current.mix) else { return kAudioHardwareBadObjectError }
        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: Self.aggregateUID,
            kAudioAggregateDeviceNameKey as String: "Seiren Mixer",
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceIsStackedKey as String: 0,
            kAudioAggregateDeviceMasterSubDeviceKey as String: fxUID,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: fxUID],
                [kAudioSubDeviceUIDKey as String: mixUID, kAudioSubDeviceDriftCompensationKey as String: 1],
            ],
            kAudioAggregateDeviceTapListKey as String: tapList,
            kAudioAggregateDeviceTapAutoStartKey as String: 1,
        ]
        let (created, device) = hardware.createAggregate(description)
        guard created == noErr else { return created }
        aggregate = device
        hardware.setBufferFrameSize(device, 256)
        // FX supplies the clock, and the voice route owns its nominal rate.
        // Never set FX's rate from here. Aggregate drift compensation resamples
        // Stream Mix and taps to this clock, including 44.1/88.2/96 kHz.
        let fxInputs = hardware.streamCount(current.fx, scope: kAudioObjectPropertyScopeInput)
        let mixInputs = hardware.streamCount(current.mix, scope: kAudioObjectPropertyScopeInput)
        let fxOutputs = hardware.streamCount(current.fx, scope: kAudioObjectPropertyScopeOutput)
        let mixOutputs = hardware.streamCount(current.mix, scope: kAudioObjectPropertyScopeOutput)
        guard fxInputs > 0, mixOutputs > 0,
              fxInputs + mixInputs + descriptions.count <= Int(SEIREN_MIXER_MAX_INPUTS) else {
            return kAudioHardwareUnsupportedOperationError
        }
        var map = IndexMap()
        for input in 0..<fxInputs { map.inputChannels[input] = 0 }
        map.ignoredInputs = Array(fxInputs..<(fxInputs + mixInputs))
        for (index, tap) in descriptions.enumerated() {
            map.inputChannels[fxInputs + mixInputs + index] = tap.0
        }
        map.mixOutput = fxOutputs
        map.silencedOutputs = (0..<(fxOutputs + mixOutputs)).filter { $0 != map.mixOutput }
        guard let dsp = seiren_mixer_create(hardware.nominalRate(device), Int32(map.mixOutput)) else {
            return kAudioHardwareUnspecifiedError
        }
        self.dsp = dsp
        for (input, channel) in map.inputChannels {
            seiren_mixer_map_input(dsp, Int32(input), Int32(channel))
        }
        lastDiagnostics = Diagnostics(indexMap: map, sampleRate: hardware.nominalRate(device), taps: tapDiagnostics)
        publishGains()
        let (procStatus, proc) = hardware.createIOProc(on: device, seiren_mixer_proc(),
                                                       clientData: UnsafeMutableRawPointer(dsp))
        guard procStatus == noErr, let proc else { return procStatus == noErr ? kAudioHardwareUnspecifiedError : procStatus }
        self.proc = proc
        // Unused streams must be disabled at the HAL, not merely ignored in
        // the callback: otherwise another Seiren instance sees us recording
        // Stream Mix and keeps both mixers running indefinitely.
        let inputStreams = hardware.streamCount(device, scope: kAudioObjectPropertyScopeInput)
        let outputStreams = hardware.streamCount(device, scope: kAudioObjectPropertyScopeOutput)
        let inputUsage = (0..<inputStreams).map { !map.ignoredInputs.contains($0) }
        let outputUsage = (0..<outputStreams).map { $0 >= fxOutputs }
        let inputStatus = hardware.setIOProcStreamUsage(device, proc: proc,
            scope: kAudioObjectPropertyScopeInput, enabled: inputUsage)
        guard inputStatus == noErr else { return inputStatus }
        let outputStatus = hardware.setIOProcStreamUsage(device, proc: proc,
            scope: kAudioObjectPropertyScopeOutput, enabled: outputUsage)
        guard outputStatus == noErr else { return outputStatus }
        return hardware.startIOProc(proc, on: device)
    }

    private func teardown() {
        if isStarted {
            EventLog.shared.log(category: .mixer, message: "stop")
            isStarted = false
        }
        if let aggregate, let proc {
            hardware.stopIOProc(proc, on: aggregate)
            hardware.destroyIOProc(proc, on: aggregate)
        }
        proc = nil
        if let aggregate { hardware.destroyAggregateDevice(aggregate) }
        aggregate = nil
        for tap in tapIDs { hardware.destroyProcessTap(tap) }
        tapIDs = []
        if let dsp {
            lastDiagnostics = diagnostics
            seiren_mixer_destroy(dsp)
            self.dsp = nil
        }
    }

    private func installSystemListeners() {
        if let listener = addListener(.devices) { systemListeners.append(listener) }
        if Self.supportedOS, let listener = addListener(.processObjects, debounced: true) {
            systemListeners.append(listener)
        }
    }

    private func updateDeviceListeners(fx: AudioObjectID?, mix: AudioObjectID?) {
        for listener in deviceListeners { hardware.removeListener(listener) }
        deviceListeners = []
        if let fx, let listener = addListener(.sampleRate(fx)) { deviceListeners.append(listener) }
        if let mix, let listener = addListener(.isRunningSomewhere(mix)) { deviceListeners.append(listener) }
    }

    private func addListener(_ property: AudioHardwareProperty, debounced: Bool = false) -> AudioHardwareListener? {
        hardware.addListener(for: property) { [weak self] in
            guard let self, !self.isShutdown else { return }
            if debounced { self.scheduleProcessRefresh() }
            else { self.reconcile() }
        }
    }

    private func scheduleProcessRefresh() {
        guard isEnabled else { return }
        debounce?.cancel()
        debounce = clock.schedule(after: 0.3, repeats: false) { [weak self] in self?.reconcile() }
    }

    private func notify() { delegate?.mixerEngineDidChange(self) }
}
