import XCTest
import CoreAudio
@testable import SeirenKit

/// Runs the whole mixer on `FakeMixerHardware`: the path from a hardware
/// event through reconciliation to taps, the aggregate, the IOProc and state,
/// which the policy-function tests do not reach and which needs no audio device here.
@MainActor
final class MixerEngineFakeHardwareTests: XCTestCase {
    private typealias Device = FakeMixerHardware.Device
    private typealias Process = FakeMixerHardware.Process

    private let fx = Device(id: 20, uid: MonitorEngine.fxDeviceUID, name: "Seiren FX", inputStreams: 1)
    private let streamMix = Device(id: 30, uid: MonitorEngine.streamMixDeviceUID, name: "Seiren Stream Mix",
                                   inputStreams: 1)
    private let streamMixFeeder = Device(id: 31, uid: MonitorEngine.streamMixFeederUID,
                                         name: "Seiren Stream Mix Feeder", outputStreams: 1, isHidden: true)
    private let ownProcess = Process(id: 100, pid: 1100)
    private let obs = Process(id: 200, pid: 1200, bundleID: "com.obsproject.obs-studio")
    private let spotify = Process(id: 300, pid: 1300, bundleID: "com.spotify.client")

    /// The driver installed, Spotify playing into its own channel, and nothing
    /// recording Stream Mix yet.
    private func makeIdleMixer() -> (FakeMixerHardware, MixerEngine) {
        let hardware = FakeMixerHardware(devices: [fx, streamMix, streamMixFeeder],
                                         processes: [ownProcess, obs, spotify], ownProcess: ownProcess.id)
        let mixer = MixerEngine(hardware: hardware, clock: FakeClock())
        mixer.addApp(bundleID: "com.spotify.client", name: "Spotify")
        mixer.setEnabled(true)
        return (hardware, mixer)
    }

    private func startRecording(_ process: Process, on hardware: FakeMixerHardware) {
        let index = hardware.processes.firstIndex { $0.id == process.id }!
        hardware.processes[index].recordingFrom = [streamMix.id]
        hardware.fireRunningStateChanged(on: streamMix.id)
    }

    private func stopRecording(_ process: Process, on hardware: FakeMixerHardware) {
        let index = hardware.processes.firstIndex { $0.id == process.id }!
        hardware.processes[index].recordingFrom = []
        hardware.fireRunningStateChanged(on: streamMix.id)
    }

    func testAppRecordingStreamMixStartsTheMixer() throws {
        let (hardware, mixer) = makeIdleMixer()
        defer { mixer.shutdown() }
        XCTAssertEqual(mixer.state, .idle)
        XCTAssertTrue(hardware.taps.isEmpty)
        XCTAssertTrue(hardware.aggregates.isEmpty)

        startRecording(obs, on: hardware)

        XCTAssertEqual(mixer.state, .running)
        // Desktop audio leaves out the recorder, this process and every app
        // with its own channel; Spotify's channel taps only Spotify.
        XCTAssertEqual(hardware.taps, [
            MixerTap(processes: .allExcept([ownProcess.id, obs.id, spotify.id]), name: "Seiren Mixer: Desktop audio"),
            MixerTap(processes: .only([spotify.id]), name: "Seiren Mixer: Spotify"),
        ])
        let aggregate = try XCTUnwrap(hardware.aggregates.first)
        XCTAssertEqual(hardware.aggregates.count, 1)
        let tapIDs = hardware.calls.compactMap { call -> AudioObjectID? in
            if case .createTap(let id, _) = call { id } else { nil }
        }
        XCTAssertEqual(hardware.calls.last { if case .createAggregate = $0 { true } else { false } },
                       .createAggregate(aggregate, subDeviceUIDs: [fx.uid, streamMixFeeder.uid],
                                        tapUIDs: tapIDs.map { "fake-tap-\($0)" }))
        XCTAssertEqual(hardware.ioProcs, [aggregate])
        XCTAssertEqual(hardware.runningIOProcs, [aggregate])
        XCTAssertEqual(mixer.diagnostics.taps, [MixerEngine.Tap(channelName: "Desktop audio", processCount: 3),
                                                MixerEngine.Tap(channelName: "Spotify", processCount: 1)])
    }

    func testAppStoppingRecordingDestroysEverything() throws {
        let (hardware, mixer) = makeIdleMixer()
        defer { mixer.shutdown() }
        startRecording(obs, on: hardware)
        XCTAssertEqual(mixer.state, .running)
        let aggregate = try XCTUnwrap(hardware.aggregates.first)

        stopRecording(obs, on: hardware)

        XCTAssertEqual(mixer.state, .idle)
        XCTAssertTrue(hardware.runningIOProcs.isEmpty)
        XCTAssertTrue(hardware.ioProcs.isEmpty, "the IOProc must be destroyed, not only stopped")
        XCTAssertTrue(hardware.aggregates.isEmpty)
        XCTAssertTrue(hardware.taps.isEmpty)
        let stop = try XCTUnwrap(hardware.calls.firstIndex(of: .stopIOProc(device: aggregate)))
        let destroy = try XCTUnwrap(hardware.calls.firstIndex(of: .destroyIOProc(device: aggregate)))
        XCTAssertLessThan(stop, destroy, "the IOProc must stop before it is destroyed")
    }

    func testFXWithoutStreamMixNeedsADriverUpdate() {
        let hardware = FakeMixerHardware(processes: [ownProcess], ownProcess: ownProcess.id)
        let mixer = MixerEngine(hardware: hardware, clock: FakeClock())
        defer { mixer.shutdown() }
        mixer.setEnabled(true)
        XCTAssertEqual(mixer.state, .needsFX)

        // A driver from before Stream Mix existed.
        hardware.devices.append(fx)
        hardware.fireDevicesChanged()

        XCTAssertEqual(mixer.state, .needsDriverUpdate)
        XCTAssertEqual(mixer.availability, .needsDriverUpdate)
        XCTAssertTrue(hardware.calls.isEmpty, "nothing may be created without Stream Mix")
    }
}
