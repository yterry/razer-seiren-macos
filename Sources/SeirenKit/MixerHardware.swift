import CoreAudio
import Foundation

/// A process tap as `MixerEngine` asks for it. The real hardware turns it into
/// a private, unmuted stereo `CATapDescription`, so the protocol needs no
/// macOS 14.2 types.
package struct MixerTap: Equatable, Sendable {
    package enum Processes: Equatable, Sendable {
        /// Every process except these: the Desktop audio channel.
        case allExcept([AudioObjectID])
        /// Only these processes: one app's channel.
        case only([AudioObjectID])
    }

    package var processes: Processes
    package var name: String

    package init(processes: Processes, name: String) {
        self.processes = processes
        self.name = name
    }
}

/// Everything `MixerEngine` asks of Core Audio. The engine reaches the HAL
/// only through this protocol, so tests can run it on an in-memory fake.
/// `CoreAudioHardware` is the real implementation.
@MainActor
package protocol MixerHardware: AnyObject {
    // MARK: Devices

    func fxDevice() -> AudioObjectID?
    func streamMixDevice() -> AudioObjectID?
    /// The device the mixer writes Stream Mix to: the hidden feeder, or
    /// Stream Mix itself on a driver whose Stream Mix has output streams.
    func streamMixOutputDevice() -> AudioObjectID?
    func deviceUID(_ device: AudioObjectID) -> String?
    func isAlive(_ device: AudioObjectID) -> Bool
    func streamCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int
    func nominalRate(_ device: AudioObjectID) -> Double
    /// Best effort: the device clamps the size to its range, and a failure is ignored.
    func setBufferFrameSize(_ device: AudioObjectID, _ frames: UInt32)

    // MARK: Processes

    /// Nil when the per-process API is unavailable (before macOS 14).
    func recordingProcesses(fromAny devices: Set<AudioObjectID>) -> [AudioDevices.RecordingProcess]?
    /// Every process object the HAL knows.
    func processObjects() -> [AudioObjectID]
    func processPID(_ process: AudioObjectID) -> pid_t?
    func processBundleID(_ process: AudioObjectID) -> String?
    func executablePath(_ pid: pid_t) -> String?
    /// This process's own process object.
    func ownProcessObject() -> AudioObjectID?

    // MARK: Process taps

    /// `uid` names the tap in an aggregate's tap list.
    func createProcessTap(_ tap: MixerTap) -> (status: OSStatus, id: AudioObjectID, uid: String)
    func destroyProcessTap(_ tap: AudioObjectID)

    // MARK: Aggregate devices

    /// `description` uses the `kAudioAggregateDevice...` keys. Returns the
    /// HAL's status, which the mixer reports when the start fails.
    func createAggregate(_ description: [String: Any]) -> (status: OSStatus, id: AudioObjectID)
    func destroyAggregateDevice(_ aggregate: AudioObjectID)

    // MARK: IOProcs

    func createIOProc(on device: AudioObjectID, _ proc: AudioDeviceIOProc,
                      clientData: UnsafeMutableRawPointer?) -> (status: OSStatus, id: AudioDeviceIOProcID?)
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

/// The members `AudioHardware` lacks. The rest of `MixerHardware` is the same
/// forwarding `CoreAudioHardware` already does for `MonitorEngine`.
extension CoreAudioHardware: MixerHardware {
    // MARK: Devices

    package func streamMixOutputDevice() -> AudioObjectID? { AudioDevices.streamMixOutputDevice() }

    // MARK: Processes

    package func processObjects() -> [AudioObjectID] { AudioDevices.processObjects() }
    package func processPID(_ process: AudioObjectID) -> pid_t? { AudioDevices.processPID(process) }
    package func processBundleID(_ process: AudioObjectID) -> String? { AudioDevices.processBundleID(process) }
    package func executablePath(_ pid: pid_t) -> String? { AudioDevices.executablePath(pid) }
    package func ownProcessObject() -> AudioObjectID? { AudioDevices.ownProcessObject() }

    // MARK: Process taps

    package func createProcessTap(_ tap: MixerTap) -> (status: OSStatus, id: AudioObjectID, uid: String) {
        guard #available(macOS 14.2, *) else { return (kAudioHardwareUnsupportedOperationError, 0, "") }
        let description = switch tap.processes {
        case .allExcept(let processes): CATapDescription(stereoGlobalTapButExcludeProcesses: processes)
        case .only(let processes): CATapDescription(stereoMixdownOfProcesses: processes)
        }
        description.name = tap.name
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var id: AudioObjectID = 0
        let status = AudioHardwareCreateProcessTap(description, &id)
        return (status, id, description.uuid.uuidString)
    }

    package func destroyProcessTap(_ tap: AudioObjectID) {
        if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tap) }
    }

    // MARK: Aggregate devices

    package func createAggregate(_ description: [String: Any]) -> (status: OSStatus, id: AudioObjectID) {
        var aggregate: AudioObjectID = 0
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        return (status, aggregate)
    }

    // MARK: IOProcs

    package func createIOProc(on device: AudioObjectID, _ proc: AudioDeviceIOProc,
                              clientData: UnsafeMutableRawPointer?) -> (status: OSStatus, id: AudioDeviceIOProcID?) {
        var id: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(device, proc, clientData, &id)
        return (status, id)
    }
}
