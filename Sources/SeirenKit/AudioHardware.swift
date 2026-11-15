import CoreAudio
import Foundation

/// A property `MonitorEngine` or `MixerEngine` listens to for changes.
package enum AudioHardwareProperty: Hashable, Sendable {
    /// The system device list: plug, unplug, and driver restarts.
    case devices
    /// The system process list: apps starting, stopping, or starting audio.
    case processObjects
    case defaultInput
    case defaultOutput
    /// The nominal sample rate of one device.
    case sampleRate(AudioObjectID)
    /// Whether any process is running I/O on one device.
    case isRunningSomewhere(AudioObjectID)
}

/// Identifies one installed listener so exactly that listener can be removed.
package struct AudioHardwareListener: Hashable, Sendable {
    package let id: Int

    package init(id: Int) { self.id = id }
}

/// Everything `MonitorEngine` asks of Core Audio. The engine reaches the HAL
/// only through this protocol, so tests can run it on an in-memory fake.
/// `CoreAudioHardware` is the real implementation.
@MainActor
package protocol AudioHardware: AnyObject {
    // MARK: Devices

    func candidates() -> [MonitorEngine.Candidate]
    func fxDevice() -> AudioObjectID?
    func fxOutputDevice() -> AudioObjectID?
    func streamMixDevice() -> AudioObjectID?
    func defaultInputDevice() -> AudioObjectID?
    func defaultOutputDevice() -> AudioObjectID?
    /// Also resolves hidden devices, which the device list leaves out.
    func device(forUID uid: String) -> AudioObjectID?
    func deviceUID(_ device: AudioObjectID) -> String?
    func isAlive(_ device: AudioObjectID) -> Bool
    func streamCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int
    func nominalRate(_ device: AudioObjectID) -> Double
    /// Best effort: the device clamps the size to its range, and a failure is ignored.
    func setBufferFrameSize(_ device: AudioObjectID, _ frames: UInt32)
    func diagnosticsDevices() -> [DiagnosticsSnapshot.Device]
    func diagnosticsDevice(_ device: AudioObjectID) -> DiagnosticsSnapshot.Device?

    // MARK: Recording processes

    var recordingProcessesSupported: Bool { get }
    /// Nil when the per-process API is unavailable (before macOS 14).
    func recordingProcesses(fromAny devices: Set<AudioObjectID>) -> [AudioDevices.RecordingProcess]?
    /// The devices this process is recording from, or nil when it is not recording.
    func ownInputDeviceIDs() -> [AudioObjectID]?

    // MARK: Aggregate devices

    /// `description` uses the `kAudioAggregateDevice...` keys. Nil on failure.
    func createAggregateDevice(_ description: [String: Any]) -> AudioObjectID?
    func destroyAggregateDevice(_ aggregate: AudioObjectID)

    // MARK: IOProcs

    func createIOProc(on device: AudioObjectID, _ proc: AudioDeviceIOProc) -> (status: OSStatus, id: AudioDeviceIOProcID?)
    /// One flag per stream in `scope`, in stream order.
    func setIOProcStreamUsage(_ device: AudioObjectID, proc: AudioDeviceIOProcID,
                              scope: AudioObjectPropertyScope, enabled: [Bool]) -> OSStatus
    func startIOProc(_ proc: AudioDeviceIOProcID, on device: AudioObjectID) -> OSStatus
    @discardableResult
    func stopIOProc(_ proc: AudioDeviceIOProcID, on device: AudioObjectID) -> OSStatus
    func destroyIOProc(_ proc: AudioDeviceIOProcID, on device: AudioObjectID)

    // MARK: Property listeners

    /// `handler` runs on the main actor after each change. Nil when the
    /// listener could not be installed.
    func addListener(for property: AudioHardwareProperty,
                     _ handler: @escaping @MainActor @Sendable () -> Void) -> AudioHardwareListener?
    func removeListener(_ listener: AudioHardwareListener)
}

/// The real hardware: forwards to `AudioDevices` and the HAL.
@MainActor
package final class CoreAudioHardware: AudioHardware {
    private struct Registration {
        var object: AudioObjectID
        var address: AudioObjectPropertyAddress
        /// The HAL removes a listener by the block it was added with.
        var block: AudioObjectPropertyListenerBlock
    }

    private var registrations: [AudioHardwareListener: Registration] = [:]
    private var lastListenerID = 0

    package init() {}

    // MARK: Devices

    package func candidates() -> [MonitorEngine.Candidate] { AudioDevices.candidates() }
    package func fxDevice() -> AudioObjectID? { AudioDevices.fxDevice() }
    package func fxOutputDevice() -> AudioObjectID? { AudioDevices.fxOutputDevice() }
    package func streamMixDevice() -> AudioObjectID? { AudioDevices.streamMixDevice() }
    package func defaultInputDevice() -> AudioObjectID? { AudioDevices.defaultInputDevice() }
    package func defaultOutputDevice() -> AudioObjectID? { AudioDevices.defaultOutputDevice() }
    package func device(forUID uid: String) -> AudioObjectID? { AudioDevices.device(forUID: uid) }
    package func deviceUID(_ device: AudioObjectID) -> String? { AudioDevices.deviceUID(device) }
    package func isAlive(_ device: AudioObjectID) -> Bool { AudioDevices.isAlive(device) }

    package func streamCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        AudioDevices.streamCount(device, scope: scope)
    }

    package func nominalRate(_ device: AudioObjectID) -> Double { AudioDevices.nominalRate(device) }

    package func setBufferFrameSize(_ device: AudioObjectID, _ frames: UInt32) {
        AudioDevices.setBufferFrameSize(device, frames)
    }

    package func diagnosticsDevices() -> [DiagnosticsSnapshot.Device] { AudioDevices.diagnosticsDevices() }

    package func diagnosticsDevice(_ device: AudioObjectID) -> DiagnosticsSnapshot.Device? {
        AudioDevices.diagnosticsDevice(device)
    }

    // MARK: Recording processes

    package var recordingProcessesSupported: Bool { AudioDevices.recordingProcessesSupported }

    package func recordingProcesses(fromAny devices: Set<AudioObjectID>) -> [AudioDevices.RecordingProcess]? {
        AudioDevices.recordingProcesses(fromAny: devices)
    }

    package func ownInputDeviceIDs() -> [AudioObjectID]? {
        guard let process = AudioDevices.ownProcessObject(),
              AudioDevices.processIsRunningInput(process) == true else { return nil }
        return AudioDevices.processInputDeviceIDs(process)
    }

    // MARK: Aggregate devices

    package func createAggregateDevice(_ description: [String: Any]) -> AudioObjectID? {
        var aggregate: AudioObjectID = 0
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        return (status == noErr && aggregate != 0) ? aggregate : nil
    }

    package func destroyAggregateDevice(_ aggregate: AudioObjectID) {
        AudioHardwareDestroyAggregateDevice(aggregate)
    }

    // MARK: IOProcs

    package func createIOProc(on device: AudioObjectID,
                              _ proc: AudioDeviceIOProc) -> (status: OSStatus, id: AudioDeviceIOProcID?) {
        var id: AudioDeviceIOProcID?
        // inClientData = nil: the procs read only globals, so they need no
        // context. Handing them an object would invite touching it from the
        // RT thread, which is exactly what they must not do.
        let status = AudioDeviceCreateIOProcID(device, proc, nil, &id)
        return (status, id)
    }

    package func setIOProcStreamUsage(_ device: AudioObjectID, proc: AudioDeviceIOProcID,
                                      scope: AudioObjectPropertyScope, enabled: [Bool]) -> OSStatus {
        AudioDevices.setIOProcStreamUsage(device, proc: proc, scope: scope, enabled: enabled)
    }

    package func startIOProc(_ proc: AudioDeviceIOProcID, on device: AudioObjectID) -> OSStatus {
        AudioDeviceStart(device, proc)
    }

    @discardableResult
    package func stopIOProc(_ proc: AudioDeviceIOProcID, on device: AudioObjectID) -> OSStatus {
        AudioDeviceStop(device, proc)
    }

    package func destroyIOProc(_ proc: AudioDeviceIOProcID, on device: AudioObjectID) {
        AudioDeviceDestroyIOProcID(device, proc)
    }

    // MARK: Property listeners

    package func addListener(for property: AudioHardwareProperty,
                             _ handler: @escaping @MainActor @Sendable () -> Void) -> AudioHardwareListener? {
        let object: AudioObjectID
        let selector: AudioObjectPropertySelector
        switch property {
        case .devices:
            (object, selector) = (AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        case .processObjects:
            (object, selector) = (AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        case .defaultInput:
            (object, selector) = (AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
        case .defaultOutput:
            (object, selector) = (AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        case .sampleRate(let device):
            (object, selector) = (device, kAudioDevicePropertyNominalSampleRate)
        case .isRunningSomewhere(let device):
            (object, selector) = (device, kAudioDevicePropertyDeviceIsRunningSomewhere)
        }
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in handler() }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr else {
            return nil
        }
        lastListenerID += 1
        let listener = AudioHardwareListener(id: lastListenerID)
        registrations[listener] = Registration(object: object, address: address, block: block)
        return listener
    }

    package func removeListener(_ listener: AudioHardwareListener) {
        guard var registration = registrations.removeValue(forKey: listener) else { return }
        AudioObjectRemovePropertyListenerBlock(registration.object, &registration.address,
                                               DispatchQueue.main, registration.block)
    }
}
