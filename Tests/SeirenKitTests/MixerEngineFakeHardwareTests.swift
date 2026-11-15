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
    private let discord = Process(id: 400, pid: 1400, bundleID: "com.hnc.Discord")

    private var clock: FakeClock!

    override func setUp() async throws {
        try await super.setUp()
        clock = FakeClock()
    }

    override func tearDown() async throws {
        clock = nil
        try await super.tearDown()
    }

    /// The driver installed, Spotify playing into its own channel, and nothing
    /// recording Stream Mix yet.
    private func makeIdleMixer() -> (FakeMixerHardware, MixerEngine) {
        let hardware = FakeMixerHardware(devices: [fx, streamMix, streamMixFeeder],
                                         processes: [ownProcess, obs, spotify], ownProcess: ownProcess.id)
        let mixer = MixerEngine(hardware: hardware, clock: clock)
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
        let mixer = MixerEngine(hardware: hardware, clock: clock)
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

    // MARK: Failed starts

    func testTapCreationFailureDestroysTheTapsAlreadyCreated() throws {
        let (hardware, mixer) = makeIdleMixer()
        // Desktop audio's tap is created, then Spotify's fails.
        hardware.tapResults = [noErr, kAudioHardwareIllegalOperationError]

        startRecording(obs, on: hardware)

        XCTAssertEqual(mixer.state, .failed(kAudioHardwareIllegalOperationError))
        let created = try XCTUnwrap(hardware.calls.compactMap { call -> AudioObjectID? in
            if case .createTap(let id, _) = call { id } else { nil }
        }.first)
        XCTAssertTrue(hardware.calls.contains(.destroyTap(created)))
        XCTAssertTrue(hardware.taps.isEmpty)
        XCTAssertEqual(aggregatesCreated(hardware), 0)
        assertShutdownLeavesNothing(mixer, hardware)
    }

    func testAggregateCreationFailureDestroysTheTaps() {
        let (hardware, mixer) = makeIdleMixer()
        hardware.aggregateResults = [kAudioHardwareBadDeviceError]

        startRecording(obs, on: hardware)

        XCTAssertEqual(mixer.state, .failed(kAudioHardwareBadDeviceError))
        XCTAssertEqual(tapsCreated(hardware), 2)
        XCTAssertTrue(hardware.taps.isEmpty)
        XCTAssertTrue(hardware.aggregates.isEmpty)
        XCTAssertTrue(hardware.ioProcs.isEmpty)
        assertShutdownLeavesNothing(mixer, hardware)
    }

    func testIOProcStartFailureDestroysTheIOProcAggregateAndTaps() {
        let (hardware, mixer) = makeIdleMixer()
        hardware.startResults = [kAudioHardwareNotRunningError]

        startRecording(obs, on: hardware)

        XCTAssertEqual(mixer.state, .failed(kAudioHardwareNotRunningError))
        XCTAssertEqual(startAttempts(hardware), 1)
        XCTAssertTrue(hardware.runningIOProcs.isEmpty)
        XCTAssertTrue(hardware.ioProcs.isEmpty)
        XCTAssertTrue(hardware.aggregates.isEmpty)
        XCTAssertTrue(hardware.taps.isEmpty)
        assertShutdownLeavesNothing(mixer, hardware)
    }

    // MARK: Retrying a failed start

    func testFailedStartRetriesAfterFiveSecondsAndRecovers() {
        let (hardware, mixer) = makeIdleMixer()
        let mark = EventLog.shared.recent.last
        hardware.startResults = [kAudioHardwareNotRunningError]

        startRecording(obs, on: hardware)
        XCTAssertEqual(mixer.state, .failed(kAudioHardwareNotRunningError))
        clock.advance(by: 4.5)
        XCTAssertEqual(startAttempts(hardware), 1, "no retry before 5 s")
        XCTAssertEqual(mixer.state, .failed(kAudioHardwareNotRunningError))

        clock.advance(by: 1.5)

        XCTAssertEqual(startAttempts(hardware), 2)
        XCTAssertEqual(mixer.state, .running)
        XCTAssertEqual(mixerMessages(after: mark), [
            "start failed: status=\(kAudioHardwareNotRunningError)",
            "start: 3 channels, 2 taps",
            "start recovered after 2 attempts",
        ])
        assertShutdownLeavesNothing(mixer, hardware)
    }

    func testRepeatedFailedStartsWaitFiveTenTwentyThenSixtySeconds() {
        let (hardware, mixer) = makeIdleMixer()
        hardware.startResults = Array(repeating: kAudioHardwareNotRunningError, count: 6)

        startRecording(obs, on: hardware)
        var times = [clock.uptime]
        times += attemptTimes(5, on: hardware)

        // The 1.5 s poll makes each attempt, so it lands up to 1.5 s after the delay.
        for (index, delay) in [5.0, 10, 20, 60, 60].enumerated() {
            let gap = times[index + 1] - times[index]
            XCTAssertGreaterThanOrEqual(gap, delay, "attempt \(index + 2)")
            XCTAssertLessThan(gap, delay + 1.5, "attempt \(index + 2)")
        }
        XCTAssertEqual(mixer.state, .failed(kAudioHardwareNotRunningError))
        assertShutdownLeavesNothing(mixer, hardware)
    }

    func testTwentyFailuresWithTheSameStatusLogOneEntry() {
        let (hardware, mixer) = makeIdleMixer()
        let mark = EventLog.shared.recent.last
        hardware.startResults = Array(repeating: kAudioHardwareNotRunningError, count: 20)

        startRecording(obs, on: hardware)
        _ = attemptTimes(19, on: hardware)

        XCTAssertEqual(startAttempts(hardware), 20)
        XCTAssertEqual(mixerMessages(after: mark), ["start failed: status=\(kAudioHardwareNotRunningError)"])

        // A different status is logged again.
        hardware.startResults = [kAudioHardwareUnspecifiedError]
        _ = attemptTimes(1, on: hardware)
        XCTAssertEqual(mixer.state, .failed(kAudioHardwareUnspecifiedError))
        XCTAssertEqual(mixerMessages(after: mark), ["start failed: status=\(kAudioHardwareNotRunningError)",
                                                    "start failed: status=\(kAudioHardwareUnspecifiedError)"])
        assertShutdownLeavesNothing(mixer, hardware)
    }

    func testRetryNowStartsAtOnce() {
        let (hardware, mixer) = makeIdleMixer()
        hardware.startResults = [kAudioHardwareNotRunningError]
        startRecording(obs, on: hardware)
        XCTAssertEqual(mixer.state, .failed(kAudioHardwareNotRunningError))

        mixer.retryNow()

        XCTAssertEqual(startAttempts(hardware), 2)
        XCTAssertEqual(mixer.state, .running)
        assertShutdownLeavesNothing(mixer, hardware)
    }

    func testRetryNowThatWorksLogsTheRecovery() {
        let (hardware, mixer) = makeIdleMixer()
        let mark = EventLog.shared.recent.last
        hardware.startResults = [kAudioHardwareNotRunningError]
        startRecording(obs, on: hardware)
        XCTAssertEqual(mixer.state, .failed(kAudioHardwareNotRunningError))

        mixer.retryNow()

        XCTAssertEqual(mixer.state, .running)
        XCTAssertEqual(mixerMessages(after: mark), [
            "start failed: status=\(kAudioHardwareNotRunningError)",
            "start: 3 channels, 2 taps",
            "start recovered after 2 attempts",
        ])
        assertShutdownLeavesNothing(mixer, hardware)
    }

    func testTurningTheMixerOffAndOnStartsAtOnce() {
        let (hardware, mixer) = makeIdleMixer()
        hardware.startResults = [kAudioHardwareNotRunningError]
        startRecording(obs, on: hardware)
        XCTAssertEqual(mixer.state, .failed(kAudioHardwareNotRunningError))

        mixer.setEnabled(false)
        XCTAssertEqual(mixer.state, .off)
        mixer.setEnabled(true)

        XCTAssertEqual(startAttempts(hardware), 2)
        XCTAssertEqual(mixer.state, .running)
        assertShutdownLeavesNothing(mixer, hardware)
    }

    // MARK: Changes while running

    func testDevicesReturningWithTheSameIDsGetANewAggregate() throws {
        let (hardware, mixer) = makeIdleMixer()
        startRecording(obs, on: hardware)
        let old = try XCTUnwrap(hardware.aggregates.first)
        let mark = hardware.calls.count

        // A coreaudiod restart: every device goes away, our aggregate with
        // them, and the driver's devices come back with the same IDs.
        hardware.devices.removeAll()
        hardware.devices = [fx, streamMix, streamMixFeeder]
        hardware.fireDevicesChanged()

        XCTAssertEqual(mixer.state, .running)
        XCTAssertEqual(aggregatesCreated(hardware, since: mark), 1)
        let new = try XCTUnwrap(hardware.aggregates.first)
        XCTAssertNotEqual(new, old)
        XCTAssertEqual(hardware.aggregates, [new])
        XCTAssertEqual(hardware.runningIOProcs, [new])
        assertShutdownLeavesNothing(mixer, hardware)
    }

    func testAddingAnAppChannelWhileRunningRestartsOnceWithATapForIt() {
        let (hardware, mixer) = makeIdleMixer()
        hardware.processes.append(discord)
        startRecording(obs, on: hardware)
        let mark = hardware.calls.count

        mixer.addApp(bundleID: "com.hnc.Discord", name: "Discord")

        XCTAssertEqual(mixer.state, .running)
        XCTAssertEqual(aggregatesDestroyed(hardware, since: mark), 1)
        XCTAssertEqual(aggregatesCreated(hardware, since: mark), 1)
        XCTAssertEqual(startAttempts(hardware, since: mark), 1)
        XCTAssertEqual(hardware.taps, [
            MixerTap(processes: .allExcept([ownProcess.id, obs.id, spotify.id, discord.id]),
                     name: "Seiren Mixer: Desktop audio"),
            MixerTap(processes: .only([spotify.id]), name: "Seiren Mixer: Spotify"),
            MixerTap(processes: .only([discord.id]), name: "Seiren Mixer: Discord"),
        ])
        assertShutdownLeavesNothing(mixer, hardware)
    }

    func testFXSampleRateChangeRestartsAtTheNewRate() throws {
        let (hardware, mixer) = makeIdleMixer()
        startRecording(obs, on: hardware)
        XCTAssertEqual(mixer.diagnostics.sampleRate, 48000)
        let mark = hardware.calls.count

        let index = try XCTUnwrap(hardware.devices.firstIndex { $0.id == fx.id })
        hardware.devices[index].sampleRate = 96000
        hardware.fireSampleRateChanged(on: fx.id)

        XCTAssertEqual(mixer.state, .running)
        XCTAssertEqual(aggregatesDestroyed(hardware, since: mark), 1)
        XCTAssertEqual(aggregatesCreated(hardware, since: mark), 1)
        XCTAssertEqual(mixer.diagnostics.sampleRate, 96000)
        assertShutdownLeavesNothing(mixer, hardware)
    }

    func testRecordingAppStoppingAndStartingAgainGoesIdleAndBack() {
        let (hardware, mixer) = makeIdleMixer()
        startRecording(obs, on: hardware)
        XCTAssertEqual(mixer.state, .running)

        stopRecording(obs, on: hardware)
        XCTAssertEqual(mixer.state, .idle)
        XCTAssertTrue(hardware.aggregates.isEmpty)
        let mark = hardware.calls.count

        startRecording(obs, on: hardware)

        XCTAssertEqual(mixer.state, .running)
        XCTAssertEqual(aggregatesCreated(hardware, since: mark), 1)
        XCTAssertEqual(hardware.aggregates.count, 1)
        assertShutdownLeavesNothing(mixer, hardware)
    }

    // MARK: Helpers

    private func calls(_ hardware: FakeMixerHardware, since mark: Int,
                       where match: (FakeMixerHardware.Call) -> Bool) -> Int {
        hardware.calls[mark...].filter(match).count
    }

    private func tapsCreated(_ hardware: FakeMixerHardware, since mark: Int = 0) -> Int {
        calls(hardware, since: mark) { if case .createTap = $0 { true } else { false } }
    }

    private func aggregatesCreated(_ hardware: FakeMixerHardware, since mark: Int = 0) -> Int {
        calls(hardware, since: mark) { if case .createAggregate = $0 { true } else { false } }
    }

    private func aggregatesDestroyed(_ hardware: FakeMixerHardware, since mark: Int = 0) -> Int {
        calls(hardware, since: mark) { if case .destroyAggregate = $0 { true } else { false } }
    }

    /// Each start that gets as far as starting the IOProc.
    private func startAttempts(_ hardware: FakeMixerHardware, since mark: Int = 0) -> Int {
        calls(hardware, since: mark) { if case .startIOProc = $0 { true } else { false } }
    }

    /// Advances the clock one 1.5 s poll at a time until `count` more starts
    /// have been attempted, and returns the time of each.
    private func attemptTimes(_ count: Int, on hardware: FakeMixerHardware,
                              file: StaticString = #filePath, line: UInt = #line) -> [TimeInterval] {
        var times: [TimeInterval] = []
        var attempts = startAttempts(hardware)
        for _ in 0..<1000 where times.count < count {
            clock.advance(by: 1.5)
            let now = startAttempts(hardware)
            XCTAssertLessThanOrEqual(now, attempts + 1, "one attempt per poll", file: file, line: line)
            if now > attempts { times.append(clock.uptime) }
            attempts = now
        }
        XCTAssertEqual(times.count, count, "attempts made", file: file, line: line)
        return times
    }

    /// The mixer's event log messages after `mark`, the last entry before the test acted.
    private func mixerMessages(after mark: EventLog.Entry?) -> [String] {
        let recent = EventLog.shared.recent
        let start = mark.flatMap { recent.lastIndex(of: $0) }.map { $0 + 1 } ?? 0
        return recent[start...].filter { $0.category == .mixer }.map(\.message)
    }

    private func assertShutdownLeavesNothing(_ mixer: MixerEngine, _ hardware: FakeMixerHardware,
                                             file: StaticString = #filePath, line: UInt = #line) {
        mixer.shutdown()
        XCTAssertEqual(mixer.state, .off, file: file, line: line)
        XCTAssertTrue(hardware.taps.isEmpty, "taps left: \(hardware.taps)", file: file, line: line)
        XCTAssertTrue(hardware.aggregates.isEmpty, "aggregates left: \(hardware.aggregates)", file: file, line: line)
        XCTAssertTrue(hardware.ioProcs.isEmpty, "IOProcs left: \(hardware.ioProcs)", file: file, line: line)
        XCTAssertTrue(hardware.runningIOProcs.isEmpty, file: file, line: line)
        XCTAssertTrue(hardware.listenedProperties.isEmpty,
                      "listeners left: \(hardware.listenedProperties)", file: file, line: line)
        XCTAssertEqual(clock.pendingTimerCount, 0, "timers left", file: file, line: line)
    }
}
