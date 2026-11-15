import CoreAudio
import Foundation
@testable import SeirenKit

/// In-memory `MixerHardware`, so `MixerEngine` runs with no audio device.
/// A test edits `devices` or `processes`, then fires the listener the HAL
/// would have fired.
@MainActor
final class FakeMixerHardware: MixerHardware {
    struct Device: Equatable {
        var id: AudioObjectID
        var uid: String
        var name: String
        var inputStreams = 0
        var outputStreams = 0
        var sampleRate = 48000.0
        /// Left out of the device list but found by UID, like the Stream Mix feeder.
        var isHidden = false
    }

    struct Process: Equatable {
        var id: AudioObjectID
        var pid: pid_t
        var bundleID: String?
        var executablePath: String?
        /// The devices this process records from.
        var recordingFrom: Set<AudioObjectID> = []
    }

    /// Every call that changes the hardware, in order.
    enum Call: Equatable {
        case createTap(AudioObjectID, MixerTap)
        case destroyTap(AudioObjectID)
        case createAggregate(AudioObjectID, subDeviceUIDs: [String], tapUIDs: [String])
        case destroyAggregate(AudioObjectID)
        case setBufferFrameSize(device: AudioObjectID, frames: UInt32)
        case createIOProc(device: AudioObjectID)
        case setStreamUsage(device: AudioObjectID, scope: AudioObjectPropertyScope, enabled: [Bool])
        case startIOProc(device: AudioObjectID)
        case stopIOProc(device: AudioObjectID)
        case destroyIOProc(device: AudioObjectID)
    }

    private struct LiveTap {
        var id: AudioObjectID
        var uid: String
        var tap: MixerTap
    }

    var devices: [Device]
    var processes: [Process]
    var ownProcess: AudioObjectID?
    var recordingProcessesSupported = true
    /// Results for the next tap creations, in order. Once it is empty, they succeed.
    var tapResults: [OSStatus] = []
    /// Results for the next aggregate creations, in order. Once it is empty, they succeed.
    var aggregateResults: [OSStatus] = []
    /// Results for the next IOProc starts, in order. Once it is empty, they succeed.
    var startResults: [OSStatus] = []

    private(set) var calls: [Call] = []
    /// Aggregates created and not yet destroyed.
    private(set) var aggregates: Set<AudioObjectID> = []
    /// Devices with an IOProc created and not yet destroyed.
    private(set) var ioProcs: Set<AudioObjectID> = []
    private(set) var runningIOProcs: Set<AudioObjectID> = []

    private var liveTaps: [LiveTap] = []
    private var listeners: [AudioHardwareListener: (property: AudioHardwareProperty, handler: @MainActor () -> Void)] = [:]
    private var lastListenerID = 0
    private var lastObjectID: AudioObjectID = 1000

    init(devices: [Device] = [], processes: [Process] = [], ownProcess: AudioObjectID? = nil) {
        self.devices = devices
        self.processes = processes
        self.ownProcess = ownProcess
    }

    /// Taps created and not yet destroyed, in creation order.
    var taps: [MixerTap] { liveTaps.map(\.tap) }
    /// The properties that currently have a listener.
    var listenedProperties: Set<AudioHardwareProperty> { Set(listeners.values.map(\.property)) }

    // MARK: Firing listeners

    func fireDevicesChanged() { fire(.devices) }
    func fireProcessListChanged() { fire(.processObjects) }
    func fireSampleRateChanged(on device: AudioObjectID) { fire(.sampleRate(device)) }
    func fireRunningStateChanged(on device: AudioObjectID) { fire(.isRunningSomewhere(device)) }

    private func fire(_ property: AudioHardwareProperty) {
        for listener in listeners.values where listener.property == property { listener.handler() }
    }

    // MARK: Devices

    private func device(_ id: AudioObjectID) -> Device? { devices.first { $0.id == id } }
    private func device(forUID uid: String) -> Device? { devices.first { $0.uid == uid } }
    private func listedDevice(uid: String) -> AudioObjectID? {
        devices.first { !$0.isHidden && $0.uid == uid }?.id
    }

    func fxDevice() -> AudioObjectID? { listedDevice(uid: MonitorEngine.fxDeviceUID) }
    func streamMixDevice() -> AudioObjectID? { listedDevice(uid: MonitorEngine.streamMixDeviceUID) }

    func streamMixOutputDevice() -> AudioObjectID? {
        device(forUID: MonitorEngine.streamMixFeederUID)?.id
            ?? streamMixDevice().flatMap { streamCount($0, scope: kAudioObjectPropertyScopeOutput) > 0 ? $0 : nil }
    }

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

    // MARK: Processes

    func recordingProcesses(fromAny devices: Set<AudioObjectID>) -> [AudioDevices.RecordingProcess]? {
        guard recordingProcessesSupported else { return nil }
        return processes.filter { !$0.recordingFrom.isDisjoint(with: devices) }.map {
            AudioDevices.RecordingProcess(pid: $0.pid, bundleID: $0.bundleID, objectID: $0.id,
                                          inputDeviceIDs: $0.recordingFrom.sorted())
        }
    }

    func processObjects() -> [AudioObjectID] { processes.map(\.id) }
    func processPID(_ process: AudioObjectID) -> pid_t? { processes.first { $0.id == process }?.pid }
    func processBundleID(_ process: AudioObjectID) -> String? { processes.first { $0.id == process }?.bundleID }
    func executablePath(_ pid: pid_t) -> String? { processes.first { $0.pid == pid }?.executablePath }
    func ownProcessObject() -> AudioObjectID? { ownProcess }

    // MARK: Process taps

    func createProcessTap(_ tap: MixerTap) -> (status: OSStatus, id: AudioObjectID, uid: String) {
        let status = tapResults.isEmpty ? noErr : tapResults.removeFirst()
        guard status == noErr else { return (status, 0, "") }
        lastObjectID += 1
        let created = LiveTap(id: lastObjectID, uid: "fake-tap-\(lastObjectID)", tap: tap)
        liveTaps.append(created)
        calls.append(.createTap(created.id, tap))
        return (noErr, created.id, created.uid)
    }

    func destroyProcessTap(_ tap: AudioObjectID) {
        liveTaps.removeAll { $0.id == tap }
        calls.append(.destroyTap(tap))
    }

    // MARK: Aggregate devices

    /// Fails, as the HAL does, when the UID is taken or a sub-device or tap is missing.
    func createAggregate(_ description: [String: Any]) -> (status: OSStatus, id: AudioObjectID) {
        let status = aggregateResults.isEmpty ? noErr : aggregateResults.removeFirst()
        guard status == noErr else { return (status, 0) }
        guard let uid = description[kAudioAggregateDeviceUIDKey] as? String,
              let name = description[kAudioAggregateDeviceNameKey] as? String,
              let subDeviceList = description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]],
              device(forUID: uid) == nil else { return (kAudioHardwareIllegalOperationError, 0) }
        let tapList = description[kAudioAggregateDeviceTapListKey] as? [[String: Any]] ?? []
        let subDeviceUIDs = subDeviceList.compactMap { $0[kAudioSubDeviceUIDKey] as? String }
        let tapUIDs = tapList.compactMap { $0[kAudioSubTapUIDKey] as? String }
        let subDevices = subDeviceUIDs.compactMap { device(forUID: $0) }
        guard !subDevices.isEmpty, subDevices.count == subDeviceList.count, tapUIDs.count == tapList.count,
              tapUIDs.allSatisfy({ uid in liveTaps.contains { $0.uid == uid } }) else {
            return (kAudioHardwareBadObjectError, 0)
        }
        lastObjectID += 1
        // Each tap adds one input stream after the sub-devices' own.
        devices.append(Device(id: lastObjectID, uid: uid, name: name,
                              inputStreams: subDevices.map(\.inputStreams).reduce(0, +) + tapUIDs.count,
                              outputStreams: subDevices.map(\.outputStreams).reduce(0, +),
                              sampleRate: subDevices[0].sampleRate, isHidden: true))
        aggregates.insert(lastObjectID)
        calls.append(.createAggregate(lastObjectID, subDeviceUIDs: subDeviceUIDs, tapUIDs: tapUIDs))
        return (noErr, lastObjectID)
    }

    func destroyAggregateDevice(_ aggregate: AudioObjectID) {
        devices.removeAll { $0.id == aggregate }
        aggregates.remove(aggregate)
        calls.append(.destroyAggregate(aggregate))
    }

    // MARK: IOProcs

    func createIOProc(on device: AudioObjectID, _ proc: AudioDeviceIOProc,
                      clientData: UnsafeMutableRawPointer?) -> (status: OSStatus, id: AudioDeviceIOProcID?) {
        guard isAlive(device) else { return (kAudioHardwareBadDeviceError, nil) }
        ioProcs.insert(device)
        calls.append(.createIOProc(device: device))
        return (noErr, proc)
    }

    func setIOProcStreamUsage(_ device: AudioObjectID, proc: AudioDeviceIOProcID,
                              scope: AudioObjectPropertyScope, enabled: [Bool]) -> OSStatus {
        calls.append(.setStreamUsage(device: device, scope: scope, enabled: enabled))
        return noErr
    }

    func startIOProc(_ proc: AudioDeviceIOProcID, on device: AudioObjectID) -> OSStatus {
        calls.append(.startIOProc(device: device))
        let status = startResults.isEmpty ? noErr : startResults.removeFirst()
        if status == noErr { runningIOProcs.insert(device) }
        return status
    }

    @discardableResult
    func stopIOProc(_ proc: AudioDeviceIOProcID, on device: AudioObjectID) -> OSStatus {
        runningIOProcs.remove(device)
        calls.append(.stopIOProc(device: device))
        return noErr
    }

    func destroyIOProc(_ proc: AudioDeviceIOProcID, on device: AudioObjectID) {
        runningIOProcs.remove(device)
        ioProcs.remove(device)
        calls.append(.destroyIOProc(device: device))
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
