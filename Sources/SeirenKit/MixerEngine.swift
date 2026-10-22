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

    /// The outermost app owns helpers inside nested app bundles. A resolver
    /// keeps attribution deterministic in tests; production reads Info.plist
    /// through Foundation Bundle, without introducing AppKit into SeirenKit.
    nonisolated package static func owningAppBundleID(
        bundleID: String?, executablePath: String?,
        bundleIdentifier: (String) -> String? = { Bundle(path: $0)?.bundleIdentifier }
    ) -> String? {
        // WebKit exposes no public responsible-app identity. Attribute these
        // services to Safari, including WebKit audio used by other host apps.
        if bundleID == "com.apple.WebKit.GPU" || bundleID == "com.apple.WebKit.WebContent" {
            return "com.apple.Safari"
        }
        if let executablePath {
            var path = ""
            for component in (executablePath as NSString).pathComponents {
                path = (path as NSString).appendingPathComponent(component)
                if component.lowercased().hasSuffix(".app") {
                    return bundleIdentifier(path) ?? bundleID
                }
            }
        }
        return bundleID
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
                       hasFX: AudioDevices.fxDevice() != nil,
                       hasStreamMix: AudioDevices.streamMixDevice() != nil, hasRecorders: false)
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

    private struct Snapshot: Equatable {
        var fx: AudioObjectID
        var mix: AudioObjectID
        var rate: Double
        var apps: [Set<AudioObjectID>]
        var recorders: Set<AudioObjectID>
        var ownProcess: AudioObjectID
    }

    private struct Listener {
        var object: AudioObjectID
        var selector: AudioObjectPropertySelector
        var block: AudioObjectPropertyListenerBlock
    }

    private let runWithoutRecorder: Bool
    private var isShutdown = false
    private var timer: Timer?
    private var debounce: Timer?
    private var listeners: [Listener] = []
    private var fxObserved: AudioObjectID?
    private var mixObserved: AudioObjectID?
    private var snapshot: Snapshot?
    private var aggregate: AudioObjectID?
    private var proc: AudioDeviceIOProcID?
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
    package init(runWithoutRecorder: Bool) {
        self.runWithoutRecorder = runWithoutRecorder
        installSystemListeners()
        reconcile()
    }

    public func setEnabled(_ enabled: Bool) {
        guard !isShutdown else { return }
        let changed = enabled != isEnabled
        isEnabled = enabled
        if enabled, timer == nil {
            let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.reconcile() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !enabled {
            timer?.invalidate(); timer = nil
            debounce?.invalidate(); debounce = nil
        }
        reconcile()
        if changed { notify() }
    }

    public func setChannels(_ channels: [Channel]) {
        let normalized = Self.normalizedChannels(channels)
        guard normalized != self.channels else { return }
        let sourcesChanged = normalized.map(\.source) != self.channels.map(\.source)
        self.channels = normalized
        publishGains()
        if sourcesChanged { teardown(); snapshot = nil; reconcile() }
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
        timer?.invalidate(); timer = nil
        debounce?.invalidate(); debounce = nil
        teardown()
        for listener in listeners { remove(listener) }
        listeners = []
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
        let fx = AudioDevices.fxDevice(), mix = AudioDevices.streamMixDevice()
        let devicesChanged = fx != fxObserved || mix != mixObserved
        if devicesChanged {
            updateDeviceListeners(fx: fx, mix: mix)
            fxObserved = fx; mixObserved = mix
            notify()
        }
        let recorders = mix.map { AudioDevices.recordingProcesses(fromAny: [$0]) ?? [] } ?? []
        let desired = Self.runPolicy(enabled: isEnabled, supportedOS: Self.supportedOS,
            hasFX: fx != nil, hasStreamMix: mix != nil,
            hasRecorders: runWithoutRecorder || !recorders.isEmpty)
        guard desired == .running, let fx, let mix else {
            teardown(); snapshot = nil; state = desired
            return
        }
        guard #available(macOS 14.2, *) else { return }
        guard let ownProcess = AudioDevices.ownProcessObject() else {
            teardown(); state = .failed(kAudioHardwareBadObjectError)
            return
        }
        var byApp: [String: Set<AudioObjectID>] = [:]
        let objects = AudioDevices.processObjects()
        // A process object lives exactly as long as its process, so its owner
        // is resolved once instead of re-reading app bundles on every poll.
        owners = owners.filter { objects.contains($0.key) }
        for object in objects {
            let owner: String?
            if let cached = owners[object] {
                owner = cached
            } else {
                let pid = AudioDevices.processPID(object)
                owner = Self.owningAppBundleID(bundleID: AudioDevices.processBundleID(object),
                    executablePath: pid.flatMap { AudioDevices.executablePath($0) })
                owners[object] = owner
            }
            if let owner { byApp[owner, default: []].insert(object) }
        }
        let appProcesses = channels.compactMap { channel -> Set<AudioObjectID>? in
            guard case .app(let id) = channel.source else { return nil }
            return byApp[id] ?? []
        }
        let current = Snapshot(fx: fx, mix: mix, rate: AudioDevices.nominalRate(fx),
            apps: appProcesses, recorders: Set(recorders.map(\.objectID)), ownProcess: ownProcess)
        guard current != snapshot || devicesChanged else { return }
        teardown()
        snapshot = current
        let status = start(current)
        if status == noErr { state = .running }
        else { teardown(); state = .failed(status) }
    }

    @available(macOS 14.2, *)
    private func start(_ current: Snapshot) -> OSStatus {
        var excluded = current.recorders.union([current.ownProcess])
        for processes in current.apps { excluded.formUnion(processes) }
        var descriptions: [(Int, CATapDescription, Int)] = [
            (1, CATapDescription(stereoGlobalTapButExcludeProcesses: excluded.sorted()), excluded.count)
        ]
        for (index, processes) in current.apps.enumerated() where !processes.isEmpty {
            descriptions.append((index + 2, CATapDescription(stereoMixdownOfProcesses:
                processes.sorted()), processes.count))
        }
        var tapList: [[String: Any]] = []
        var tapDiagnostics: [Tap] = []
        for (channel, description, count) in descriptions {
            description.name = "Seiren Mixer: \(channels[channel].name)"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            var tap: AudioObjectID = 0
            let status = AudioHardwareCreateProcessTap(description, &tap)
            guard status == noErr else { return status }
            tapIDs.append(tap)
            tapList.append([kAudioSubTapUIDKey as String: description.uuid.uuidString,
                            kAudioSubTapDriftCompensationKey as String: 1])
            tapDiagnostics.append(Tap(channelName: channels[channel].name, processCount: count))
        }
        let fxUID = MonitorEngine.fxDeviceUID, mixUID = MonitorEngine.streamMixDeviceUID
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
        var device: AudioObjectID = 0
        let created = AudioHardwareCreateAggregateDevice(description as CFDictionary, &device)
        guard created == noErr else { return created }
        aggregate = device
        AudioDevices.setBufferFrameSize(device, 256)
        // FX supplies the clock, and the voice route owns its nominal rate.
        // Never set FX's rate from here. Aggregate drift compensation resamples
        // Stream Mix and taps to this clock, including 44.1/88.2/96 kHz.
        let fxInputs = AudioDevices.streamCount(current.fx, scope: kAudioObjectPropertyScopeInput)
        let mixInputs = AudioDevices.streamCount(current.mix, scope: kAudioObjectPropertyScopeInput)
        let fxOutputs = AudioDevices.streamCount(current.fx, scope: kAudioObjectPropertyScopeOutput)
        let mixOutputs = AudioDevices.streamCount(current.mix, scope: kAudioObjectPropertyScopeOutput)
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
        guard let dsp = seiren_mixer_create(AudioDevices.nominalRate(device), Int32(map.mixOutput)) else {
            return kAudioHardwareUnspecifiedError
        }
        self.dsp = dsp
        for (input, channel) in map.inputChannels {
            seiren_mixer_map_input(dsp, Int32(input), Int32(channel))
        }
        lastDiagnostics = Diagnostics(indexMap: map, sampleRate: AudioDevices.nominalRate(device), taps: tapDiagnostics)
        publishGains()
        var proc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcID(device, seiren_mixer_proc(), UnsafeMutableRawPointer(dsp), &proc)
        guard procStatus == noErr, let proc else { return procStatus == noErr ? kAudioHardwareUnspecifiedError : procStatus }
        self.proc = proc
        return AudioDeviceStart(device, proc)
    }

    private func teardown() {
        if let aggregate, let proc {
            AudioDeviceStop(aggregate, proc)
            AudioDeviceDestroyIOProcID(aggregate, proc)
        }
        proc = nil
        if let aggregate { AudioHardwareDestroyAggregateDevice(aggregate) }
        aggregate = nil
        if #available(macOS 14.2, *) {
            for tap in tapIDs { AudioHardwareDestroyProcessTap(tap) }
        }
        tapIDs = []
        if let dsp {
            lastDiagnostics = diagnostics
            seiren_mixer_destroy(dsp)
            self.dsp = nil
        }
    }

    private func installSystemListeners() {
        addListener(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        if Self.supportedOS {
            addListener(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, debounced: true)
        }
    }

    private func updateDeviceListeners(fx: AudioObjectID?, mix: AudioObjectID?) {
        let deviceListeners = listeners.filter { $0.object != AudioObjectID(kAudioObjectSystemObject) }
        for listener in deviceListeners { remove(listener) }
        listeners.removeAll { $0.object != AudioObjectID(kAudioObjectSystemObject) }
        if let fx { addListener(fx, kAudioDevicePropertyNominalSampleRate) }
        if let mix { addListener(mix, kAudioDevicePropertyDeviceIsRunningSomewhere) }
    }

    private func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             debounced: Bool = false) {
        var address = Self.address(selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self, !self.isShutdown else { return }
                if debounced { self.scheduleProcessRefresh() }
                else { self.reconcile() }
            }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr {
            listeners.append(Listener(object: object, selector: selector, block: block))
        }
    }

    private func remove(_ listener: Listener) {
        var address = Self.address(listener.selector)
        AudioObjectRemovePropertyListenerBlock(listener.object, &address, DispatchQueue.main, listener.block)
    }

    private func scheduleProcessRefresh() {
        guard isEnabled else { return }
        debounce?.invalidate()
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
        RunLoop.main.add(timer, forMode: .common)
        debounce = timer
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func notify() { delegate?.mixerEngineDidChange(self) }
}
