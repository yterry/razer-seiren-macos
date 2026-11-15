import CoreAudio
import Foundation
@testable import SeirenKit

/// In-memory `AudioHardware`, so `MonitorEngine` runs with no audio device.
/// A test edits `devices`, then fires the listener the HAL would have fired.
/// Listeners run through `clock`, which stands in for the main queue: an
/// event runs after the call that caused it returns, in order. Creating or
/// destroying an aggregate queues a device-list event, as the HAL does.
@MainActor
final class FakeAudioHardware: AudioHardware {
    struct Device: Equatable {
        var id: AudioObjectID
        var uid: String
        var name: String
        var inputStreams = 0
        var outputStreams = 0
        var sampleRate = 48000.0
        /// Left out of the device list but found by UID, like the Seiren FX feeders.
        var isHidden = false
        var isVirtual = false
        var isBuiltIn = false
        var inputTerminalType: UInt32?
    }

    enum IOProcKind: Hashable {
        case monitor, route, standby
    }

    /// One IOProc as the engine created it: which callback, on which device.
    struct IOProc: Hashable {
        var kind: IOProcKind
        var device: AudioObjectID
    }

    /// Every call that changes the hardware, in order.
    enum Call: Equatable {
        case setBufferFrameSize(device: AudioObjectID, frames: UInt32)
        case createAggregate(AudioObjectID, subDeviceUIDs: [String])
        case destroyAggregate(AudioObjectID)
        case createIOProc(IOProc)
        case setStreamUsage(IOProc, scope: AudioObjectPropertyScope, enabled: [Bool])
        case startIOProc(IOProc)
        case stopIOProc(IOProc)
        case destroyIOProc(IOProc)
    }

    var devices: [Device]
    var defaultInputID: AudioObjectID?
    var defaultOutputID: AudioObjectID?
    var recordingProcessesSupported = true
    /// Other apps recording right now.
    var recorders: [AudioDevices.RecordingProcess] = []
    /// What this process records from, or nil when it records nothing.
    var ownInputs: [AudioObjectID]?
    /// Results for the next IOProc starts, in order. Once it is empty, starts succeed.
    var startResults: [OSStatus] = []
    /// While true, `routeCallbackCount` stays put, as for a route the HAL
    /// has stopped calling.
    var routeCallbacksFrozen = false
    private var callbackCount = 0

    private(set) var calls: [Call] = []
    /// IOProcs created and not yet destroyed.
    private(set) var ioProcs: Set<IOProc> = []
    private(set) var runningIOProcs: Set<IOProc> = []
    /// Aggregates created and not yet destroyed.
    private(set) var aggregates: Set<AudioObjectID> = []

    private var listeners: [AudioHardwareListener: (property: AudioHardwareProperty, handler: @MainActor () -> Void)] = [:]
    private var lastListenerID = 0
    private var lastAggregateID: AudioObjectID = 1000
    private let clock: FakeClock

    init(devices: [Device] = [], clock: FakeClock) {
        self.devices = devices
        self.clock = clock
    }

    /// The properties that currently have a listener.
    var listenedProperties: Set<AudioHardwareProperty> { Set(listeners.values.map(\.property)) }

    // MARK: Firing listeners

    func fireDevicesChanged() { fire(.devices) }
    func fireDefaultInputChanged() { fire(.defaultInput) }
    func fireDefaultOutputChanged() { fire(.defaultOutput) }
    func fireSampleRateChanged(on device: AudioObjectID) { fire(.sampleRate(device)) }
    func fireRunningStateChanged(on device: AudioObjectID) { fire(.isRunningSomewhere(device)) }

    /// Delivers this event and every event queued before it or caused by it.
    private func fire(_ property: AudioHardwareProperty) {
        queue(property)
        clock.advance(by: 0)
    }

    /// The HAL delivers a change through the main queue, to the listeners
    /// installed when the event runs.
    private func queue(_ property: AudioHardwareProperty) {
        _ = clock.schedule(after: 0, repeats: false) { [weak self] in
            guard let self else { return }
            for listener in self.listeners.values where listener.property == property { listener.handler() }
        }
    }

    // MARK: Devices

    private func device(_ id: AudioObjectID) -> Device? { devices.first { $0.id == id } }

    private var listedDevices: [Device] { devices.filter { !$0.isHidden } }

    func candidates() -> [MonitorEngine.Candidate] {
        listedDevices.map {
            MonitorEngine.Candidate(id: $0.id, uid: $0.uid, name: $0.name,
                                    hasInput: $0.inputStreams > 0, hasOutput: $0.outputStreams > 0,
                                    isVirtual: $0.isVirtual, isBuiltIn: $0.isBuiltIn,
                                    inputTerminalType: $0.inputTerminalType)
        }
    }

    func fxDevice() -> AudioObjectID? {
        listedDevices.first { $0.uid == MonitorEngine.fxDeviceUID }?.id
    }

    func fxOutputDevice() -> AudioObjectID? {
        device(forUID: MonitorEngine.fxFeederUID)
            ?? fxDevice().flatMap { streamCount($0, scope: kAudioObjectPropertyScopeOutput) > 0 ? $0 : nil }
    }

    func streamMixDevice() -> AudioObjectID? {
        listedDevices.first { $0.uid == MonitorEngine.streamMixDeviceUID }?.id
    }

    func defaultInputDevice() -> AudioObjectID? { defaultInputID }
    func defaultOutputDevice() -> AudioObjectID? { defaultOutputID }
    func device(forUID uid: String) -> AudioObjectID? { devices.first { $0.uid == uid }?.id }
    func deviceUID(_ device: AudioObjectID) -> String? { self.device(device)?.uid }
    func isAlive(_ device: AudioObjectID) -> Bool { self.device(device) != nil }

    func streamCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        guard let device = self.device(device) else { return 0 }
        switch scope {
        case kAudioObjectPropertyScopeInput: return device.inputStreams
        case kAudioObjectPropertyScopeOutput: return device.outputStreams
        default: return 0
        }
    }

    func nominalRate(_ device: AudioObjectID) -> Double { self.device(device)?.sampleRate ?? 48000 }

    func setBufferFrameSize(_ device: AudioObjectID, _ frames: UInt32) {
        calls.append(.setBufferFrameSize(device: device, frames: frames))
    }

    func diagnosticsDevices() -> [DiagnosticsSnapshot.Device] { devices.map(diagnostics) }

    func diagnosticsDevice(_ device: AudioObjectID) -> DiagnosticsSnapshot.Device? {
        self.device(device).map(diagnostics)
    }

    private func diagnostics(_ device: Device) -> DiagnosticsSnapshot.Device {
        DiagnosticsSnapshot.Device(uid: device.uid, name: device.name, transport: nil,
                                   inputStreams: device.inputStreams, outputStreams: device.outputStreams,
                                   sampleRate: device.sampleRate)
    }

    // MARK: Recording processes

    func recordingProcesses(fromAny devices: Set<AudioObjectID>) -> [AudioDevices.RecordingProcess]? {
        guard recordingProcessesSupported else { return nil }
        return recorders.filter { !devices.isDisjoint(with: $0.inputDeviceIDs) }
    }

    func ownInputDeviceIDs() -> [AudioObjectID]? { ownInputs }

    // MARK: Aggregate devices

    /// Fails, as the HAL does, when a sub-device is missing or the UID is taken.
    func createAggregateDevice(_ description: [String: Any]) -> AudioObjectID? {
        guard let uid = description[kAudioAggregateDeviceUIDKey] as? String,
              let name = description[kAudioAggregateDeviceNameKey] as? String,
              let list = description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]],
              device(forUID: uid) == nil else { return nil }
        let subDeviceUIDs = list.compactMap { $0[kAudioSubDeviceUIDKey] as? String }
        let subDevices = subDeviceUIDs.compactMap { subUID in devices.first { $0.uid == subUID } }
        guard !subDevices.isEmpty, subDevices.count == list.count else { return nil }
        lastAggregateID += 1
        devices.append(Device(id: lastAggregateID, uid: uid, name: name,
                              inputStreams: subDevices.map(\.inputStreams).reduce(0, +),
                              outputStreams: subDevices.map(\.outputStreams).reduce(0, +),
                              sampleRate: subDevices[0].sampleRate, isVirtual: true))
        aggregates.insert(lastAggregateID)
        calls.append(.createAggregate(lastAggregateID, subDeviceUIDs: subDeviceUIDs))
        queue(.devices)
        return lastAggregateID
    }

    /// An aggregate that is already gone, as after a coreaudiod restart,
    /// changes no device list and so queues no event.
    func destroyAggregateDevice(_ aggregate: AudioObjectID) {
        let wasListed = devices.contains { $0.id == aggregate }
        devices.removeAll { $0.id == aggregate }
        aggregates.remove(aggregate)
        calls.append(.destroyAggregate(aggregate))
        if wasListed { queue(.devices) }
    }

    // MARK: IOProcs

    /// The fake hands the callback back as its own ID, so later calls can
    /// tell which of the engine's three callbacks they refer to.
    private func ioProc(_ proc: AudioDeviceIOProc, on device: AudioObjectID) -> IOProc {
        let address = unsafeBitCast(proc, to: UnsafeRawPointer.self)
        let kind: IOProcKind
        switch address {
        case unsafeBitCast(monitorIOProc, to: UnsafeRawPointer.self): kind = .monitor
        case unsafeBitCast(routeIOProc, to: UnsafeRawPointer.self): kind = .route
        case unsafeBitCast(standbyIOProc, to: UnsafeRawPointer.self): kind = .standby
        default: preconditionFailure("an IOProc the engine does not own")
        }
        return IOProc(kind: kind, device: device)
    }

    func createIOProc(on device: AudioObjectID, _ proc: AudioDeviceIOProc) -> (status: OSStatus, id: AudioDeviceIOProcID?) {
        guard isAlive(device) else { return (kAudioHardwareBadDeviceError, nil) }
        let created = ioProc(proc, on: device)
        ioProcs.insert(created)
        calls.append(.createIOProc(created))
        return (noErr, proc)
    }

    func setIOProcStreamUsage(_ device: AudioObjectID, proc: AudioDeviceIOProcID,
                              scope: AudioObjectPropertyScope, enabled: [Bool]) -> OSStatus {
        calls.append(.setStreamUsage(ioProc(proc, on: device), scope: scope, enabled: enabled))
        return noErr
    }

    func startIOProc(_ proc: AudioDeviceIOProcID, on device: AudioObjectID) -> OSStatus {
        let started = ioProc(proc, on: device)
        calls.append(.startIOProc(started))
        let status = startResults.isEmpty ? noErr : startResults.removeFirst()
        if status == noErr { runningIOProcs.insert(started) }
        return status
    }

    @discardableResult
    func stopIOProc(_ proc: AudioDeviceIOProcID, on device: AudioObjectID) -> OSStatus {
        let stopped = ioProc(proc, on: device)
        runningIOProcs.remove(stopped)
        calls.append(.stopIOProc(stopped))
        return noErr
    }

    func destroyIOProc(_ proc: AudioDeviceIOProcID, on device: AudioObjectID) {
        let destroyed = ioProc(proc, on: device)
        runningIOProcs.remove(destroyed)
        ioProcs.remove(destroyed)
        calls.append(.destroyIOProc(destroyed))
    }

    /// Advances on each read, like a route that keeps cycling, unless frozen.
    var routeCallbackCount: Int {
        if !routeCallbacksFrozen { callbackCount += 1 }
        return callbackCount
    }

    // MARK: Property listeners

    func addListener(for property: AudioHardwareProperty,
                     _ handler: @escaping @MainActor @Sendable () -> Void) -> AudioHardwareListener? {
        lastListenerID += 1
        let listener = AudioHardwareListener(id: lastListenerID)
        listeners[listener] = (property, handler)
        return listener
    }

    func removeListener(_ listener: AudioHardwareListener) {
        listeners[listener] = nil
    }
}

/// A clock that only moves when a test advances it. Work scheduled with no
/// delay runs on the next `advance`, even `advance(by: 0)`, which is how
/// `FakeAudioHardware` delivers events through the main queue.
@MainActor
final class FakeClock: EngineClock {
    private final class FakeTimer: EngineTimer {
        var fireAt: TimeInterval
        let interval: TimeInterval
        let repeats: Bool
        let action: @MainActor () -> Void
        var isCancelled = false

        init(fireAt: TimeInterval, interval: TimeInterval, repeats: Bool, action: @escaping @MainActor () -> Void) {
            self.fireAt = fireAt
            self.interval = interval
            self.repeats = repeats
            self.action = action
        }

        func cancel() { isCancelled = true }
    }

    private(set) var uptime: TimeInterval = 1000
    private var timers: [FakeTimer] = []

    /// Timers scheduled and neither cancelled nor, for one-shot timers, fired.
    var pendingTimerCount: Int { timers.filter { !$0.isCancelled }.count }

    func schedule(after interval: TimeInterval, repeats: Bool,
                  _ action: @escaping @MainActor @Sendable () -> Void) -> any EngineTimer {
        precondition(!repeats || interval > 0, "a repeating timer needs a positive interval")
        let timer = FakeTimer(fireAt: uptime + interval, interval: interval, repeats: repeats, action: action)
        timers.append(timer)
        return timer
    }

    /// Moves time forward, firing each due timer in order at its own fire time.
    func advance(by interval: TimeInterval) {
        let end = uptime + interval
        while let next = timers.filter({ !$0.isCancelled && $0.fireAt <= end })
            .min(by: { $0.fireAt < $1.fireAt }) {
            uptime = next.fireAt
            if next.repeats { next.fireAt += next.interval } else { next.isCancelled = true }
            next.action()
        }
        timers.removeAll(where: \.isCancelled)
        uptime = end
    }
}
