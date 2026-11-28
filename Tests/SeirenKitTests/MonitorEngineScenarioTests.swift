import XCTest
import CoreAudio
@testable import SeirenKit

/// The plug, unplug, sleep, wake and driver-restart sequences users hit,
/// run end to end on `FakeAudioHardware` and `FakeClock`. Each test checks
/// the engine state, the active source, and the hardware calls, then shuts
/// the engine down and checks that nothing is left behind in the fakes.
@MainActor
final class MonitorEngineScenarioTests: XCTestCase {
    private typealias Device = FakeAudioHardware.Device
    private typealias IOProc = FakeAudioHardware.IOProc
    private typealias Call = FakeAudioHardware.Call
    private typealias InputDevice = MonitorEngine.InputDevice

    private let seiren = Device(id: 10, uid: "seiren-uid", name: "Razer Seiren V3 Pro",
                                inputStreams: 1, outputStreams: 1)
    private let mini = Device(id: 11, uid: "mini-uid", name: "Razer Seiren V3 Mini", inputStreams: 1)
    private let fx = Device(id: 20, uid: MonitorEngine.fxDeviceUID, name: "Seiren FX", inputStreams: 1)
    private let fxFeeder = Device(id: 21, uid: MonitorEngine.fxFeederUID, name: "Seiren FX Feeder",
                                  outputStreams: 1, isHidden: true)
    private let builtInMic = Device(id: 30, uid: "builtin-mic-uid", name: "MacBook Pro Microphone",
                                    inputStreams: 1, isBuiltIn: true,
                                    inputTerminalType: kAudioStreamTerminalTypeMicrophone)
    private let headset = Device(id: 31, uid: "headset-uid", name: "USB Headset", inputStreams: 1, outputStreams: 1,
                                 inputTerminalType: kAudioStreamTerminalTypeHeadsetMicrophone)

    private var clock: FakeClock!

    override func setUp() async throws {
        try await super.setUp()
        clock = FakeClock()
    }

    override func tearDown() async throws {
        // Starting a route sets the globals the RT procs read; restore the
        // defaults other tests assume.
        gMonitorEnabled = true
        gMonitorOutBuffers = 1
        clock = nil
        try await super.tearDown()
    }

    // MARK: Scenarios

    func testAlwaysModeSeirenUnpluggedAndPluggedBackIn() {
        let hardware = FakeAudioHardware(devices: [seiren], clock: clock)
        let engine = makeEngine(on: hardware)
        let monitor = IOProc(kind: .monitor, device: seiren.id)

        engine.setMode(.always)
        XCTAssertEqual(engine.state, .running)
        XCTAssertEqual(engine.activeSource, input(seiren, isSeiren: true))
        XCTAssertEqual(lifecycleCalls(hardware), [.createIOProc(monitor), .startIOProc(monitor)])

        var mark = hardware.calls.count
        unplug(seiren, from: hardware)
        XCTAssertEqual(engine.state, .noDevice)
        XCTAssertNil(engine.activeSource)
        XCTAssertEqual(engine.mode, .always, "unplugging must not change the monitoring choice")
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [.stopIOProc(monitor), .destroyIOProc(monitor)])
        XCTAssertTrue(hardware.ioProcs.isEmpty)

        mark = hardware.calls.count
        plug(seiren, into: hardware)
        XCTAssertEqual(engine.state, .running)
        XCTAssertEqual(engine.activeSource, input(seiren, isSeiren: true))
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [.createIOProc(monitor), .startIOProc(monitor)])
        XCTAssertEqual(hardware.runningIOProcs, [monitor])

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testAutoModeWithFXSeirenUnpluggedDuringRecordingFallsBackToDefaultInputAndBack() throws {
        // The headset is the default input; the built-in mic must not win over it.
        let hardware = FakeAudioHardware(devices: [builtInMic, headset, seiren, fx, fxFeeder], clock: clock)
        hardware.defaultInputID = headset.id
        let engine = makeEngine(on: hardware)
        let standby = IOProc(kind: .standby, device: seiren.id)

        engine.setMode(.auto)
        XCTAssertEqual(engine.state, .waiting)
        XCTAssertEqual(engine.activeSource, input(seiren, isSeiren: true))
        XCTAssertEqual(hardware.runningIOProcs, [standby])

        // A call app starts recording from Seiren FX.
        hardware.recorders = [recorder(on: fx.id)]
        hardware.fireRunningStateChanged(on: fx.id)
        XCTAssertEqual(engine.state, .running)
        XCTAssertTrue(engine.isRoutingThroughFX)
        let seirenAggregate = try XCTUnwrap(hardware.aggregates.first)
        XCTAssertEqual(lastAggregateSubDevices(hardware), [seiren.uid, fxFeeder.uid])
        XCTAssertEqual(hardware.runningIOProcs, [standby, IOProc(kind: .route, device: seirenAggregate)])

        // The Seiren is unplugged mid-call: Seiren FX keeps carrying the voice
        // from the default input.
        var mark = hardware.calls.count
        unplug(seiren, from: hardware)
        XCTAssertEqual(engine.state, .running)
        XCTAssertEqual(engine.mode, .auto)
        XCTAssertEqual(engine.activeSource, input(headset, isSeiren: false))
        XCTAssertTrue(engine.isRoutingThroughFX)
        XCTAssertFalse(engine.isStandbyRunning)
        XCTAssertFalse(gMonitorEnabled, "another mic must never play its own voice back")
        let headsetAggregate = try XCTUnwrap(hardware.aggregates.first)
        let seirenRoute = IOProc(kind: .route, device: seirenAggregate)
        let headsetRoute = IOProc(kind: .route, device: headsetAggregate)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [
            .stopIOProc(standby), .destroyIOProc(standby),
            .stopIOProc(seirenRoute), .destroyIOProc(seirenRoute), .destroyAggregate(seirenAggregate),
            .createAggregate(headsetAggregate, subDeviceUIDs: [headset.uid, fxFeeder.uid]),
            .createIOProc(headsetRoute), .startIOProc(headsetRoute),
        ])
        XCTAssertEqual(hardware.runningIOProcs, [headsetRoute])

        // The Seiren returns while the call goes on and takes the route back.
        mark = hardware.calls.count
        plug(seiren, into: hardware)
        XCTAssertEqual(engine.state, .running)
        XCTAssertEqual(engine.activeSource, input(seiren, isSeiren: true))
        XCTAssertTrue(engine.isRoutingThroughFX)
        XCTAssertTrue(engine.isStandbyRunning)
        XCTAssertTrue(gMonitorEnabled)
        let returnedAggregate = try XCTUnwrap(hardware.aggregates.first)
        let returnedRoute = IOProc(kind: .route, device: returnedAggregate)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [
            .createIOProc(standby), .startIOProc(standby),
            .stopIOProc(headsetRoute), .destroyIOProc(headsetRoute), .destroyAggregate(headsetAggregate),
            .createAggregate(returnedAggregate, subDeviceUIDs: [seiren.uid, fxFeeder.uid]),
            .createIOProc(returnedRoute), .startIOProc(returnedRoute),
        ])
        XCTAssertEqual(hardware.runningIOProcs, [standby, returnedRoute])

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testPinnedInputDisappearsThenAutomaticTakesOverUntilItReturns() throws {
        let hardware = FakeAudioHardware(devices: [seiren, headset, fx, fxFeeder], clock: clock)
        hardware.recorders = [recorder(on: fx.id)]
        let engine = makeEngine(on: hardware)
        let pinned = MonitorEngine.InputPreference.device(uid: headset.uid)

        engine.setInputPreference(pinned)
        engine.setMode(.always)
        XCTAssertEqual(engine.state, .running)
        XCTAssertEqual(engine.activeSource, input(headset, isSeiren: false))
        XCTAssertEqual(lastAggregateSubDevices(hardware), [headset.uid, fxFeeder.uid])
        let headsetAggregate = try XCTUnwrap(hardware.aggregates.first)
        let headsetRoute = IOProc(kind: .route, device: headsetAggregate)

        // The pinned input is unplugged: Automatic picks the Seiren.
        var mark = hardware.calls.count
        unplug(headset, from: hardware)
        XCTAssertEqual(engine.state, .running)
        XCTAssertEqual(engine.inputPreference, pinned, "the pinned choice must survive the unplug")
        XCTAssertEqual(engine.activeSource, input(seiren, isSeiren: true))
        let seirenAggregate = try XCTUnwrap(hardware.aggregates.first)
        let seirenRoute = IOProc(kind: .route, device: seirenAggregate)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [
            .stopIOProc(headsetRoute), .destroyIOProc(headsetRoute), .destroyAggregate(headsetAggregate),
            .createAggregate(seirenAggregate, subDeviceUIDs: [seiren.uid, fxFeeder.uid]),
            .createIOProc(seirenRoute), .startIOProc(seirenRoute),
        ])

        // The pinned input returns and takes the route back.
        mark = hardware.calls.count
        plug(headset, into: hardware)
        XCTAssertEqual(engine.state, .running)
        XCTAssertEqual(engine.activeSource, input(headset, isSeiren: false))
        let returnedAggregate = try XCTUnwrap(hardware.aggregates.first)
        let returnedRoute = IOProc(kind: .route, device: returnedAggregate)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [
            .stopIOProc(seirenRoute), .destroyIOProc(seirenRoute), .destroyAggregate(seirenAggregate),
            .createAggregate(returnedAggregate, subDeviceUIDs: [headset.uid, fxFeeder.uid]),
            .createIOProc(returnedRoute), .startIOProc(returnedRoute),
        ])
        XCTAssertEqual(hardware.runningIOProcs, [returnedRoute])

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testListedDeadPinFallsBackToSeirenUntilThePinRecovers() throws {
        let hardware = FakeAudioHardware(devices: [headset, seiren, fx, fxFeeder], clock: clock)
        hardware.deadDevices = [headset.id]
        hardware.recorders = [recorder(on: fx.id)]
        let engine = makeEngine(on: hardware)
        let pinned = MonitorEngine.InputPreference.device(uid: headset.uid)
        engine.setInputPreference(pinned)
        engine.setMode(.always)

        XCTAssertEqual(engine.state, .running)
        XCTAssertEqual(engine.inputPreference, pinned)
        XCTAssertEqual(engine.activeSource, input(seiren, isSeiren: true))
        let seirenAggregate = try XCTUnwrap(hardware.aggregates.first)
        let seirenRoute = IOProc(kind: .route, device: seirenAggregate)
        XCTAssertEqual(lifecycleCalls(hardware), [
            .createAggregate(seirenAggregate, subDeviceUIDs: [seiren.uid, fxFeeder.uid]),
            .createIOProc(seirenRoute), .startIOProc(seirenRoute),
        ])

        var mark = hardware.calls.count
        hardware.deadDevices.remove(headset.id)
        hardware.fireDevicesChanged()
        XCTAssertEqual(engine.activeSource, input(headset, isSeiren: false))
        let headsetAggregate = try XCTUnwrap(hardware.aggregates.first)
        let headsetRoute = IOProc(kind: .route, device: headsetAggregate)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [
            .stopIOProc(seirenRoute), .destroyIOProc(seirenRoute), .destroyAggregate(seirenAggregate),
            .createAggregate(headsetAggregate, subDeviceUIDs: [headset.uid, fxFeeder.uid]),
            .createIOProc(headsetRoute), .startIOProc(headsetRoute),
        ])
        let queryMark = hardware.livenessQueries.count
        clock.advance(by: 3)
        XCTAssertFalse(hardware.livenessQueries[queryMark...].contains(seiren.id),
                       "polling a live pin should not query lower-ranked microphones")

        mark = hardware.calls.count
        hardware.deadDevices = [headset.id, seiren.id]
        hardware.fireDevicesChanged()
        XCTAssertEqual(engine.state, .noDevice)
        XCTAssertNil(engine.activeSource)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [
            .stopIOProc(headsetRoute), .destroyIOProc(headsetRoute), .destroyAggregate(headsetAggregate),
        ])
        XCTAssertTrue(hardware.runningIOProcs.isEmpty)
        assertShutdownLeavesNothing(engine, hardware)
    }

    func testListedDeadSeirenFallsBackOnlyWithFXAndARecorder() throws {
        let hardware = FakeAudioHardware(devices: [seiren, builtInMic], clock: clock)
        hardware.deadDevices = [seiren.id]
        let engine = makeEngine(on: hardware)
        engine.setMode(.always)
        XCTAssertEqual(engine.state, .noDevice)
        XCTAssertNil(engine.activeSource)
        XCTAssertEqual(lifecycleCalls(hardware), [])

        hardware.devices += [fx, fxFeeder]
        hardware.fireDevicesChanged()
        XCTAssertEqual(engine.activeSource, input(builtInMic, isSeiren: false))
        XCTAssertEqual(engine.state, .waiting)
        XCTAssertEqual(lifecycleCalls(hardware), [])

        hardware.recorders = [recorder(on: fx.id)]
        hardware.fireRunningStateChanged(on: fx.id)
        XCTAssertEqual(engine.state, .running)
        XCTAssertTrue(engine.isRoutingThroughFX)
        XCTAssertFalse(gMonitorEnabled)
        let aggregate = try XCTUnwrap(hardware.aggregates.first)
        let route = IOProc(kind: .route, device: aggregate)
        XCTAssertEqual(lifecycleCalls(hardware), [
            .createAggregate(aggregate, subDeviceUIDs: [builtInMic.uid, fxFeeder.uid]),
            .createIOProc(route), .startIOProc(route),
        ])
        assertShutdownLeavesNothing(engine, hardware)
    }

    func testTwoSeirensPreferTheFullDuplexOneAndFallBackToTheInputOnlyOne() throws {
        // The input-only Seiren is listed first, so order alone would pick it.
        let hardware = FakeAudioHardware(devices: [mini, seiren, fx, fxFeeder], clock: clock)
        let engine = makeEngine(on: hardware)

        engine.setMode(.always)
        XCTAssertEqual(engine.state, .running)
        XCTAssertEqual(engine.activeSource, input(seiren, isSeiren: true))
        XCTAssertTrue(engine.deviceHasHeadphoneOutput)
        XCTAssertEqual(engine.routeDiagnostics.monitorBuffers, 1)
        XCTAssertEqual(lastAggregateSubDevices(hardware), [seiren.uid, fxFeeder.uid])
        let seirenAggregate = try XCTUnwrap(hardware.aggregates.first)
        let seirenRoute = IOProc(kind: .route, device: seirenAggregate)

        let mark = hardware.calls.count
        unplug(seiren, from: hardware)
        XCTAssertEqual(engine.state, .running)
        XCTAssertEqual(engine.activeSource, input(mini, isSeiren: true))
        XCTAssertFalse(engine.deviceHasHeadphoneOutput)
        XCTAssertEqual(engine.routeDiagnostics.monitorBuffers, 0, "Seiren FX must lead a jack-less mic's outputs")
        let miniAggregate = try XCTUnwrap(hardware.aggregates.first)
        let miniRoute = IOProc(kind: .route, device: miniAggregate)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [
            .stopIOProc(seirenRoute), .destroyIOProc(seirenRoute), .destroyAggregate(seirenAggregate),
            .createAggregate(miniAggregate, subDeviceUIDs: [mini.uid, fxFeeder.uid]),
            .createIOProc(miniRoute), .startIOProc(miniRoute),
        ])
        XCTAssertEqual(hardware.runningIOProcs, [miniRoute])

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testInputOnlySeirenNeedsFXUntilSeirenFXIsInstalled() throws {
        let hardware = FakeAudioHardware(devices: [mini], clock: clock)
        let engine = makeEngine(on: hardware)

        engine.setMode(.always)
        XCTAssertEqual(engine.state, .needsFX)
        XCTAssertEqual(engine.activeSource, input(mini, isSeiren: true))
        XCTAssertFalse(engine.fxAvailable)
        XCTAssertEqual(lifecycleCalls(hardware), [], "with nowhere to route, nothing may open the mic")

        // Installing the driver restarts coreaudiod, which fires the hotplug listener.
        hardware.devices += [fx, fxFeeder]
        hardware.fireDevicesChanged()
        XCTAssertEqual(engine.state, .running)
        XCTAssertEqual(engine.activeSource, input(mini, isSeiren: true))
        XCTAssertTrue(engine.fxAvailable)
        XCTAssertTrue(engine.isRoutingThroughFX)
        let aggregate = try XCTUnwrap(hardware.aggregates.first)
        let route = IOProc(kind: .route, device: aggregate)
        XCTAssertEqual(lifecycleCalls(hardware), [
            .createAggregate(aggregate, subDeviceUIDs: [mini.uid, fxFeeder.uid]),
            .createIOProc(route), .startIOProc(route),
        ])

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testSeirenFXDeviceIDChangeTearsDownOnceAndStartsOnce() throws {
        let hardware = FakeAudioHardware(devices: [seiren, fx, fxFeeder], clock: clock)
        let engine = makeEngine(on: hardware)
        engine.setMode(.always)
        XCTAssertEqual(engine.state, .running)
        let firstAggregate = try XCTUnwrap(hardware.aggregates.first)
        let firstRoute = IOProc(kind: .route, device: firstAggregate)

        // A coreaudiod restart brings the driver's devices back under new IDs
        // and fires the hotplug listener more than once.
        let mark = hardware.calls.count
        for index in hardware.devices.indices where [fx.id, fxFeeder.id].contains(hardware.devices[index].id) {
            hardware.devices[index].id += 100
        }
        hardware.fireDevicesChanged()
        hardware.fireDevicesChanged()

        XCTAssertEqual(engine.state, .running)
        XCTAssertEqual(engine.activeSource, input(seiren, isSeiren: true))
        XCTAssertTrue(engine.isRoutingThroughFX)
        let secondAggregate = try XCTUnwrap(hardware.aggregates.first)
        XCTAssertNotEqual(secondAggregate, firstAggregate)
        let secondRoute = IOProc(kind: .route, device: secondAggregate)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [
            .stopIOProc(firstRoute), .destroyIOProc(firstRoute), .destroyAggregate(firstAggregate),
            .createAggregate(secondAggregate, subDeviceUIDs: [seiren.uid, fxFeeder.uid]),
            .createIOProc(secondRoute), .startIOProc(secondRoute),
        ])
        XCTAssertEqual(hardware.runningIOProcs, [secondRoute])

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testFailedStartIsRetriedAfterBackoffAndRecovers() {
        let hardware = FakeAudioHardware(devices: [seiren], clock: clock)
        hardware.startResults = [kAudioHardwareUnspecifiedError]
        let engine = makeEngine(on: hardware)
        let monitor = IOProc(kind: .monitor, device: seiren.id)

        engine.setMode(.always)
        XCTAssertEqual(engine.state, .failed(kAudioHardwareUnspecifiedError))
        XCTAssertEqual(engine.activeSource, input(seiren, isSeiren: true))
        XCTAssertTrue(engine.isRetryScheduled)
        XCTAssertEqual(lifecycleCalls(hardware), [.createIOProc(monitor), .startIOProc(monitor), .destroyIOProc(monitor)])
        XCTAssertTrue(hardware.ioProcs.isEmpty)

        // A hardware event inside the backoff must not start early.
        let mark = hardware.calls.count
        clock.advance(by: 2)
        hardware.fireDevicesChanged()
        clock.advance(by: 2.5)
        XCTAssertEqual(engine.state, .failed(kAudioHardwareUnspecifiedError))
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [])

        clock.advance(by: 0.5)
        XCTAssertEqual(engine.state, .running)
        XCTAssertFalse(engine.isRetryScheduled)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [.createIOProc(monitor), .startIOProc(monitor)])
        XCTAssertEqual(hardware.runningIOProcs, [monitor])

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testAutoModeRecorderGapShorterThanTheGracePeriodKeepsTheRoute() throws {
        let hardware = FakeAudioHardware(devices: [seiren, fx, fxFeeder], clock: clock)
        let engine = makeEngine(on: hardware)
        engine.setMode(.auto)
        XCTAssertEqual(engine.state, .waiting)

        hardware.recorders = [recorder(on: fx.id)]
        hardware.fireRunningStateChanged(on: fx.id)
        XCTAssertEqual(engine.state, .running)
        let aggregate = try XCTUnwrap(hardware.aggregates.first)
        let route = IOProc(kind: .route, device: aggregate)
        let mark = hardware.calls.count

        // The app briefly stops recording, as when a call app reopens its input.
        hardware.recorders = []
        hardware.fireRunningStateChanged(on: fx.id)
        XCTAssertEqual(engine.state, .running)
        clock.advance(by: 0.5)
        XCTAssertEqual(engine.state, .running)

        hardware.recorders = [recorder(on: fx.id)]
        hardware.fireRunningStateChanged(on: fx.id)
        // Run past the grace period and several auto polls.
        clock.advance(by: 5)

        XCTAssertEqual(engine.state, .running)
        XCTAssertEqual(engine.activeSource, input(seiren, isSeiren: true))
        XCTAssertEqual(lifecycleCalls(hardware, since: mark).filter { $0.involvesRoute }, [],
                       "a short gap must not tear the route down")
        XCTAssertTrue(hardware.runningIOProcs.contains(route))

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testStandbyStopsForSleepAndStartsAgainOnWake() {
        let hardware = FakeAudioHardware(devices: [seiren, fx, fxFeeder], clock: clock)
        let engine = makeEngine(on: hardware)
        let standby = IOProc(kind: .standby, device: seiren.id)

        engine.setMode(.auto)
        XCTAssertEqual(engine.state, .waiting)
        XCTAssertEqual(engine.activeSource, input(seiren, isSeiren: true))
        XCTAssertTrue(engine.isStandbyRunning)
        XCTAssertEqual(lifecycleCalls(hardware), [.createIOProc(standby), .startIOProc(standby)])
        XCTAssertEqual(hardware.calls.filter { if case .setStreamUsage = $0 { true } else { false } }, [
            .setStreamUsage(standby, scope: kAudioObjectPropertyScopeInput, enabled: [false]),
            .setStreamUsage(standby, scope: kAudioObjectPropertyScopeOutput, enabled: [true]),
        ], "standby must never open the mic")

        var mark = hardware.calls.count
        engine.setStandbyAllowed(false, reason: "system sleeping")
        // Auto polls keep running while asleep and must not restart standby.
        clock.advance(by: 5)
        hardware.fireDevicesChanged()
        XCTAssertFalse(engine.isStandbyRunning)
        XCTAssertEqual(engine.state, .waiting)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [.stopIOProc(standby), .destroyIOProc(standby)])
        XCTAssertTrue(hardware.ioProcs.isEmpty)

        mark = hardware.calls.count
        engine.setStandbyAllowed(true)
        clock.advance(by: 5)
        hardware.fireDevicesChanged()
        XCTAssertTrue(engine.isStandbyRunning)
        XCTAssertEqual(engine.state, .waiting)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [.createIOProc(standby), .startIOProc(standby)])
        XCTAssertEqual(hardware.runningIOProcs, [standby])

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testSampleRateChangeWhileRunningRestartsTheSameIOProc() throws {
        let hardware = FakeAudioHardware(devices: [seiren, fx, fxFeeder], clock: clock)
        let engine = makeEngine(on: hardware)
        engine.setMode(.always)
        XCTAssertEqual(engine.state, .running)
        XCTAssertEqual(engine.routeDiagnostics.sampleRate, 48000)
        let aggregate = try XCTUnwrap(hardware.aggregates.first)
        let route = IOProc(kind: .route, device: aggregate)

        let mark = hardware.calls.count
        let index = try XCTUnwrap(hardware.devices.firstIndex { $0.id == aggregate })
        hardware.devices[index].sampleRate = 96000
        hardware.fireSampleRateChanged(on: aggregate)

        XCTAssertEqual(engine.state, .running)
        XCTAssertEqual(engine.activeSource, input(seiren, isSeiren: true))
        XCTAssertEqual(engine.routeDiagnostics.sampleRate, 96000)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [.stopIOProc(route), .startIOProc(route)])
        XCTAssertEqual(hardware.aggregates, [aggregate])
        XCTAssertEqual(hardware.runningIOProcs, [route])

        assertShutdownLeavesNothing(engine, hardware)
    }

    // MARK: Start failures with microphone access reported

    func testDenialCodeWithAccessGrantedIsRetriedOnAJacklessSeiren() throws {
        let hardware = FakeAudioHardware(devices: [mini, fx, fxFeeder], clock: clock)
        hardware.startResults = [kAudioHardwareIllegalOperationError]
        let engine = makeEngine(on: hardware, microphoneAccess: { .granted })

        engine.setMode(.always)
        XCTAssertEqual(engine.state, .failed(kAudioHardwareIllegalOperationError))
        XCTAssertTrue(engine.isRetryScheduled)
        XCTAssertTrue(hardware.ioProcs.isEmpty)

        clock.advance(by: 5)
        XCTAssertEqual(engine.state, .running)
        XCTAssertTrue(engine.isRoutingThroughFX)
        XCTAssertFalse(engine.isRetryScheduled)
        let aggregate = try XCTUnwrap(hardware.aggregates.first)
        XCTAssertEqual(hardware.runningIOProcs, [IOProc(kind: .route, device: aggregate)])

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testDenialCodeOnTheFXRouteWithAccessGrantedFallsBackToDirectMonitoring() {
        let hardware = FakeAudioHardware(devices: [seiren, fx, fxFeeder], clock: clock)
        hardware.startResults = [kAudioHardwareIllegalOperationError]
        let engine = makeEngine(on: hardware, microphoneAccess: { .granted })

        engine.setMode(.always)
        XCTAssertEqual(engine.state, .running)
        XCTAssertFalse(engine.isRoutingThroughFX)
        XCTAssertEqual(hardware.runningIOProcs, [IOProc(kind: .monitor, device: seiren.id)])
        XCTAssertTrue(hardware.aggregates.isEmpty)

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testDenialCodeWithoutReportedAccessIsADenialAndIsNotRetried() {
        let hardware = FakeAudioHardware(devices: [mini, fx, fxFeeder], clock: clock)
        hardware.startResults = [kAudioHardwareIllegalOperationError]
        let engine = makeEngine(on: hardware)

        engine.setMode(.always)
        XCTAssertEqual(engine.state, .permissionDenied)
        XCTAssertFalse(engine.isRetryScheduled)

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testDenialCodeWithAccessUndeterminedIsADenial() {
        let hardware = FakeAudioHardware(devices: [mini, fx, fxFeeder], clock: clock)
        hardware.startResults = [kAudioHardwareIllegalOperationError]
        let engine = makeEngine(on: hardware, microphoneAccess: { .undetermined })

        engine.setMode(.always)
        XCTAssertEqual(engine.state, .permissionDenied)
        XCTAssertFalse(engine.isRetryScheduled)

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testDenialCodeOnSampleRateRestartWithAccessGrantedIsRetried() throws {
        let hardware = FakeAudioHardware(devices: [seiren, fx, fxFeeder], clock: clock)
        let engine = makeEngine(on: hardware, microphoneAccess: { .granted })
        engine.setMode(.always)
        XCTAssertEqual(engine.state, .running)
        let aggregate = try XCTUnwrap(hardware.aggregates.first)
        let index = try XCTUnwrap(hardware.devices.firstIndex { $0.id == aggregate })

        hardware.startResults = [kAudioHardwareIllegalOperationError]
        hardware.devices[index].sampleRate = 96000
        hardware.fireSampleRateChanged(on: aggregate)

        XCTAssertEqual(engine.state, .failed(kAudioHardwareIllegalOperationError))
        XCTAssertTrue(engine.isRetryScheduled)

        clock.advance(by: 5)
        XCTAssertEqual(engine.state, .running)

        assertShutdownLeavesNothing(engine, hardware)
    }

    // MARK: Seiren FX start fails and direct monitoring runs in its place

    func testFailedSeirenFXStartFallsBackToDirectMonitoringAndRecoversAfterBackoff() throws {
        let hardware = FakeAudioHardware(devices: [seiren, fx, fxFeeder], clock: clock)
        hardware.startResults = [kAudioHardwareUnspecifiedError]
        let engine = makeEngine(on: hardware, microphoneAccess: { .granted })
        let monitor = IOProc(kind: .monitor, device: seiren.id)

        engine.setMode(.always)
        XCTAssertEqual(engine.state, .running)
        XCTAssertFalse(engine.isRoutingThroughFX)
        XCTAssertEqual(engine.fxRouteFailure, kAudioHardwareUnspecifiedError)
        XCTAssertTrue(engine.isRetryScheduled)
        XCTAssertEqual(hardware.runningIOProcs, [monitor])
        XCTAssertTrue(hardware.aggregates.isEmpty, "the failed attempt must not leave its aggregate")

        // A hardware event inside the backoff must not start early.
        let mark = hardware.calls.count
        clock.advance(by: 2)
        hardware.fireDevicesChanged()
        clock.advance(by: 2.5)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [])
        XCTAssertEqual(engine.fxRouteFailure, kAudioHardwareUnspecifiedError)

        clock.advance(by: 0.5)
        XCTAssertEqual(engine.state, .running)
        XCTAssertTrue(engine.isRoutingThroughFX)
        XCTAssertNil(engine.fxRouteFailure)
        XCTAssertFalse(engine.isRetryScheduled)
        let aggregate = try XCTUnwrap(hardware.aggregates.first)
        let route = IOProc(kind: .route, device: aggregate)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [
            .createAggregate(aggregate, subDeviceUIDs: [seiren.uid, fxFeeder.uid]),
            .createIOProc(route), .startIOProc(route),
            .stopIOProc(monitor), .destroyIOProc(monitor),
        ], "the headphones must keep their monitor until Seiren FX has started")
        XCTAssertEqual(hardware.runningIOProcs, [route])
        XCTAssertEqual(hardware.listenedProperties.filter { if case .sampleRate = $0 { true } else { false } },
                       [.sampleRate(aggregate)])

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testRepeatedSeirenFXStartFailuresBackOffAndKeepDirectMonitoring() throws {
        let hardware = FakeAudioHardware(devices: [seiren, fx, fxFeeder], clock: clock)
        let failure = kAudioHardwareUnspecifiedError
        // The first Seiren FX start, the direct start that follows, then four retries.
        hardware.startResults = [failure, noErr, failure, failure, failure, failure]
        let engine = makeEngine(on: hardware, microphoneAccess: { .granted })
        let monitor = IOProc(kind: .monitor, device: seiren.id)

        engine.setMode(.always)
        XCTAssertEqual(engine.fxRouteFailure, failure)

        for delay in [5.0, 10, 20, 60] {
            let mark = hardware.calls.count
            clock.advance(by: delay - 0.5)
            XCTAssertEqual(lifecycleCalls(hardware, since: mark), [], "no attempt before \(delay) s")

            clock.advance(by: 0.5)
            let attempt = lifecycleCalls(hardware, since: mark)
            guard case .createAggregate(let aggregate, _)? = attempt.first else {
                return XCTFail("after \(delay) s the attempt must start with the aggregate: \(attempt)")
            }
            let route = IOProc(kind: .route, device: aggregate)
            XCTAssertEqual(attempt, [
                .createAggregate(aggregate, subDeviceUIDs: [seiren.uid, fxFeeder.uid]),
                .createIOProc(route), .startIOProc(route),
                .destroyIOProc(route), .destroyAggregate(aggregate),
            ], "after \(delay) s")
            XCTAssertEqual(engine.state, .running)
            XCTAssertEqual(engine.fxRouteFailure, failure)
            XCTAssertTrue(engine.isRetryScheduled)
            XCTAssertEqual(hardware.runningIOProcs, [monitor])
            XCTAssertTrue(hardware.aggregates.isEmpty)
        }

        // The delay stays at 60 s, and the next start succeeds.
        let mark = hardware.calls.count
        clock.advance(by: 59.5)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [])
        clock.advance(by: 0.5)
        XCTAssertTrue(engine.isRoutingThroughFX)
        XCTAssertNil(engine.fxRouteFailure)
        let aggregate = try XCTUnwrap(hardware.aggregates.first)
        XCTAssertEqual(hardware.runningIOProcs, [IOProc(kind: .route, device: aggregate)])

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testAggregateUIDAlreadyTakenFallsBackToDirectMonitoringAndRetries() throws {
        // A second copy of the app holds the aggregate's fixed UID.
        let taken = Device(id: 40, uid: MonitorEngine.aggregateUID, name: "Seiren Voice",
                           inputStreams: 2, outputStreams: 2, isHidden: true, isVirtual: true)
        let hardware = FakeAudioHardware(devices: [seiren, fx, fxFeeder, taken], clock: clock)
        let engine = makeEngine(on: hardware, microphoneAccess: { .granted })
        let monitor = IOProc(kind: .monitor, device: seiren.id)

        engine.setMode(.always)
        XCTAssertEqual(engine.state, .running)
        XCTAssertFalse(engine.isRoutingThroughFX)
        XCTAssertEqual(engine.fxRouteFailure, kAudioHardwareUnspecifiedError)
        XCTAssertTrue(engine.isRetryScheduled)
        XCTAssertEqual(lifecycleCalls(hardware), [.createIOProc(monitor), .startIOProc(monitor)])

        // Still taken at the first retry: direct monitoring goes on untouched.
        var mark = hardware.calls.count
        clock.advance(by: 5)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [])
        XCTAssertEqual(engine.fxRouteFailure, kAudioHardwareUnspecifiedError)
        XCTAssertTrue(engine.isRetryScheduled)

        // The other copy quits; the second retry is due 10 s after the first.
        hardware.devices.removeAll { $0.id == taken.id }
        mark = hardware.calls.count
        clock.advance(by: 10)
        XCTAssertTrue(engine.isRoutingThroughFX)
        XCTAssertNil(engine.fxRouteFailure)
        let aggregate = try XCTUnwrap(hardware.aggregates.first)
        let route = IOProc(kind: .route, device: aggregate)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [
            .createAggregate(aggregate, subDeviceUIDs: [seiren.uid, fxFeeder.uid]),
            .createIOProc(route), .startIOProc(route),
            .stopIOProc(monitor), .destroyIOProc(monitor),
        ])

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testRetryNowStartsSeirenFXWithoutWaitingForTheBackoff() throws {
        let hardware = FakeAudioHardware(devices: [seiren, fx, fxFeeder], clock: clock)
        hardware.startResults = [kAudioHardwareUnspecifiedError]
        let engine = makeEngine(on: hardware, microphoneAccess: { .granted })
        engine.setMode(.always)
        XCTAssertEqual(engine.fxRouteFailure, kAudioHardwareUnspecifiedError)

        clock.advance(by: 1)
        engine.retryNow()

        XCTAssertEqual(engine.state, .running)
        XCTAssertTrue(engine.isRoutingThroughFX)
        XCTAssertNil(engine.fxRouteFailure)
        XCTAssertFalse(engine.isRetryScheduled)
        let aggregate = try XCTUnwrap(hardware.aggregates.first)
        XCTAssertEqual(hardware.runningIOProcs, [IOProc(kind: .route, device: aggregate)])

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testModeOffClearsTheSeirenFXRouteFailureAndItsRetry() {
        let hardware = FakeAudioHardware(devices: [seiren, fx, fxFeeder], clock: clock)
        hardware.startResults = [kAudioHardwareUnspecifiedError]
        let engine = makeEngine(on: hardware, microphoneAccess: { .granted })
        engine.setMode(.always)
        XCTAssertEqual(engine.fxRouteFailure, kAudioHardwareUnspecifiedError)
        XCTAssertTrue(engine.isRetryScheduled)

        engine.setMode(.off)
        XCTAssertEqual(engine.state, .stopped)
        XCTAssertNil(engine.fxRouteFailure)
        XCTAssertFalse(engine.isRetryScheduled)
        let mark = hardware.calls.count
        clock.advance(by: 60)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [])

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testShutdownClearsTheSeirenFXRouteFailureAndItsRetry() {
        let hardware = FakeAudioHardware(devices: [seiren, fx, fxFeeder], clock: clock)
        hardware.startResults = [kAudioHardwareUnspecifiedError]
        let engine = makeEngine(on: hardware, microphoneAccess: { .granted })
        engine.setMode(.always)
        XCTAssertEqual(engine.fxRouteFailure, kAudioHardwareUnspecifiedError)

        assertShutdownLeavesNothing(engine, hardware)
        XCTAssertNil(engine.fxRouteFailure)
        XCTAssertFalse(engine.isRetryScheduled)
    }

    func testUnpluggingTheSeirenClearsTheFailureAndTheNextStartIsNotDelayed() throws {
        let hardware = FakeAudioHardware(devices: [seiren, fx, fxFeeder], clock: clock)
        hardware.startResults = [kAudioHardwareUnspecifiedError]
        let engine = makeEngine(on: hardware, microphoneAccess: { .granted })
        engine.setMode(.always)
        XCTAssertEqual(engine.fxRouteFailure, kAudioHardwareUnspecifiedError)

        unplug(seiren, from: hardware)
        XCTAssertEqual(engine.state, .noDevice)
        XCTAssertNil(engine.fxRouteFailure)
        XCTAssertFalse(engine.isRetryScheduled)

        // Back inside what was the backoff: the route starts at once.
        clock.advance(by: 1)
        plug(seiren, into: hardware)
        XCTAssertEqual(engine.state, .running)
        XCTAssertTrue(engine.isRoutingThroughFX)
        XCTAssertNil(engine.fxRouteFailure)
        let aggregate = try XCTUnwrap(hardware.aggregates.first)
        XCTAssertEqual(hardware.runningIOProcs, [IOProc(kind: .route, device: aggregate)])

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testSeirenFXRouteFailureIsLoggedOncePerDistinctStatusAndOnceOnRecovery() {
        let marker = "scenario \(UUID().uuidString)"
        EventLog.shared.log(category: .system, message: "\(marker)")
        let hardware = FakeAudioHardware(devices: [seiren, fx, fxFeeder], clock: clock)
        let first = kAudioHardwareUnspecifiedError
        let second = kAudioHardwareNotRunningError
        // The first Seiren FX start, the direct start, then three retries.
        hardware.startResults = [first, noErr, first, first, second]
        let engine = makeEngine(on: hardware, microphoneAccess: { .granted })

        engine.setMode(.always)
        clock.advance(by: 5)
        clock.advance(by: 10)
        clock.advance(by: 20)
        XCTAssertEqual(engine.fxRouteFailure, second)
        clock.advance(by: 60)
        XCTAssertNil(engine.fxRouteFailure)

        let recent = EventLog.shared.recent
        let start = recent.lastIndex { $0.message == marker } ?? recent.startIndex
        let route = recent[start...].filter { $0.category == .route }.map(\.message)
        XCTAssertEqual(route.filter { $0.hasPrefix("fx route") }, [
            "fx route failed status=\(first); direct monitoring continues",
            "fx route failed status=\(second); direct monitoring continues",
            "fx route recovered",
        ])
        XCTAssertEqual(route.filter { $0.hasPrefix("start failed") }.count, 1,
                       "a retry that fails must not add an entry of its own: \(route)")

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testDirectMonitoringWithoutSeirenFXSetsNoFailureAndSchedulesNoRetry() {
        let hardware = FakeAudioHardware(devices: [seiren], clock: clock)
        let engine = makeEngine(on: hardware)

        engine.setMode(.always)
        XCTAssertEqual(engine.state, .running)
        XCTAssertFalse(engine.isRoutingThroughFX)
        XCTAssertNil(engine.fxRouteFailure)
        XCTAssertFalse(engine.isRetryScheduled)
        let mark = hardware.calls.count
        clock.advance(by: 120)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [])

        assertShutdownLeavesNothing(engine, hardware)
    }

    // MARK: A route whose callbacks stop

    func testStalledRouteIsTornDownAfterSixSecondsAndStartedAgainFiveSecondsLater() throws {
        let marker = logMarker()
        let hardware = FakeAudioHardware(devices: [seiren, fx, fxFeeder], clock: clock)
        let engine = makeEngine(on: hardware)
        engine.setMode(.always)
        XCTAssertEqual(engine.state, .running)
        let firstAggregate = try XCTUnwrap(hardware.aggregates.first)
        let firstRoute = IOProc(kind: .route, device: firstAggregate)

        // The device stays listed, but the HAL stops calling the IOProc.
        var mark = hardware.calls.count
        hardware.routeCallbacksFrozen = true
        clock.advance(by: 5.9)
        XCTAssertEqual(engine.state, .running)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [])

        clock.advance(by: 0.1)
        XCTAssertEqual(engine.state, .failed(kAudioHardwareNotRunningError))
        XCTAssertTrue(engine.isRetryScheduled)
        XCTAssertEqual(engine.routeStalls, 1)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [
            .stopIOProc(firstRoute), .destroyIOProc(firstRoute), .destroyAggregate(firstAggregate),
        ])
        XCTAssertTrue(hardware.ioProcs.isEmpty)
        XCTAssertTrue(hardware.aggregates.isEmpty)

        mark = hardware.calls.count
        hardware.routeCallbacksFrozen = false
        clock.advance(by: 4.9)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [], "no attempt before 5 s")
        XCTAssertEqual(engine.state, .failed(kAudioHardwareNotRunningError))

        clock.advance(by: 0.1)
        XCTAssertEqual(engine.state, .running)
        XCTAssertFalse(engine.isRetryScheduled, "a restart that works clears the failure")
        let secondAggregate = try XCTUnwrap(hardware.aggregates.first)
        let secondRoute = IOProc(kind: .route, device: secondAggregate)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [
            .createAggregate(secondAggregate, subDeviceUIDs: [seiren.uid, fxFeeder.uid]),
            .createIOProc(secondRoute), .startIOProc(secondRoute),
        ])

        // The restarted route keeps cycling and is left alone.
        mark = hardware.calls.count
        clock.advance(by: 60)
        XCTAssertEqual(engine.state, .running)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [])
        XCTAssertEqual(engine.routeStalls, 1)
        XCTAssertEqual(stallLogEntries(since: marker), ["route stalled: no callbacks for 6 s"])

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testCallbacksThatPauseForFourSecondsAndResumeLeaveTheRouteAlone() {
        let marker = logMarker()
        let hardware = FakeAudioHardware(devices: [seiren], clock: clock)
        let engine = makeEngine(on: hardware)
        engine.setMode(.always)
        XCTAssertEqual(engine.state, .running)

        // Two pauses of two unchanged checks each, with one moving check
        // between them: the count of unchanged checks starts over.
        let mark = hardware.calls.count
        hardware.routeCallbacksFrozen = true
        clock.advance(by: 4)
        hardware.routeCallbacksFrozen = false
        clock.advance(by: 2)
        hardware.routeCallbacksFrozen = true
        clock.advance(by: 4)
        hardware.routeCallbacksFrozen = false
        clock.advance(by: 60)

        XCTAssertEqual(engine.state, .running)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [])
        XCTAssertEqual(engine.routeStalls, 0)
        XCTAssertEqual(stallLogEntries(since: marker), [])

        // Mode off stops the check with the route.
        engine.setMode(.off)
        XCTAssertEqual(clock.pendingTimerCount, 0, "timers left after mode off")

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testRepeatedStallsOnTheSameDevicesBackOffAndTheCountResetsOnceCallbacksResume() {
        let marker = logMarker()
        let hardware = FakeAudioHardware(devices: [seiren], clock: clock)
        let engine = makeEngine(on: hardware)
        let monitor = IOProc(kind: .monitor, device: seiren.id)
        engine.setMode(.always)
        hardware.routeCallbacksFrozen = true
        clock.advance(by: 6)
        XCTAssertEqual(engine.state, .failed(kAudioHardwareNotRunningError))

        // Each restart works, then stalls again 6 s later.
        for delay in [5.0, 10, 20, 60, 60] {
            var mark = hardware.calls.count
            clock.advance(by: delay - 0.1)
            XCTAssertEqual(lifecycleCalls(hardware, since: mark), [], "no attempt before \(delay) s")

            clock.advance(by: 0.1)
            XCTAssertEqual(engine.state, .running, "after \(delay) s")
            XCTAssertFalse(engine.isRetryScheduled)
            XCTAssertEqual(lifecycleCalls(hardware, since: mark), [.createIOProc(monitor), .startIOProc(monitor)])

            mark = hardware.calls.count
            clock.advance(by: 6)
            XCTAssertEqual(engine.state, .failed(kAudioHardwareNotRunningError))
            XCTAssertEqual(lifecycleCalls(hardware, since: mark), [.stopIOProc(monitor), .destroyIOProc(monitor)])
        }
        XCTAssertEqual(engine.routeStalls, 6)
        XCTAssertEqual(stallLogEntries(since: marker),
                       Array(repeating: "route stalled: no callbacks for 6 s", count: 6))

        // The next restart keeps cycling, so a later stall waits 5 s again.
        hardware.routeCallbacksFrozen = false
        clock.advance(by: 60)
        XCTAssertEqual(engine.state, .running)
        clock.advance(by: 2)
        hardware.routeCallbacksFrozen = true
        clock.advance(by: 6)
        XCTAssertEqual(engine.state, .failed(kAudioHardwareNotRunningError))
        let mark = hardware.calls.count
        clock.advance(by: 4.9)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [])
        clock.advance(by: 0.1)
        XCTAssertEqual(engine.state, .running)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [.createIOProc(monitor), .startIOProc(monitor)])
        XCTAssertEqual(engine.routeStalls, 7)

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testModeOffPartwayThroughAFreezeStopsTheStallCheckAndStartsNothing() throws {
        let marker = logMarker()
        let hardware = FakeAudioHardware(devices: [seiren, fx, fxFeeder], clock: clock)
        let engine = makeEngine(on: hardware)
        engine.setMode(.always)
        XCTAssertEqual(engine.state, .running)
        XCTAssertNotNil(hardware.aggregates.first)

        // One unchanged check has passed when the user turns monitoring off.
        hardware.routeCallbacksFrozen = true
        clock.advance(by: 3)
        XCTAssertEqual(engine.state, .running)
        engine.setMode(.off)
        XCTAssertEqual(engine.state, .stopped)
        // Deliver the device-list event that destroying the aggregate queued.
        clock.advance(by: 0)
        XCTAssertEqual(clock.pendingTimerCount, 0, "the stall check must stop with the route")

        // Run well past the 6 s stall and the 5 s retry.
        let mark = hardware.calls.count
        clock.advance(by: 30)
        XCTAssertEqual(engine.state, .stopped)
        XCTAssertFalse(engine.isRetryScheduled)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [])
        XCTAssertEqual(engine.routeStalls, 0)
        XCTAssertEqual(stallLogEntries(since: marker), [])

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testAutoRouteStoppedWhenTheRecorderLeavesPartwayThroughAFreezeIsNotRestarted() throws {
        let marker = logMarker()
        let hardware = FakeAudioHardware(devices: [seiren, fx, fxFeeder], clock: clock)
        let engine = makeEngine(on: hardware)
        engine.setMode(.auto)
        XCTAssertEqual(engine.state, .waiting)
        let waitingTimers = clock.pendingTimerCount

        hardware.recorders = [recorder(on: fx.id)]
        hardware.fireRunningStateChanged(on: fx.id)
        XCTAssertEqual(engine.state, .running)
        XCTAssertNotNil(hardware.aggregates.first)

        // One unchanged check has passed when the call app stops recording;
        // the route stops after the 1 s grace period, before a stall is due.
        hardware.routeCallbacksFrozen = true
        clock.advance(by: 3)
        XCTAssertEqual(engine.state, .running)
        hardware.recorders = []
        hardware.fireRunningStateChanged(on: fx.id)
        clock.advance(by: 1.5)
        XCTAssertEqual(engine.state, .waiting)
        XCTAssertTrue(hardware.aggregates.isEmpty)
        XCTAssertFalse(hardware.ioProcs.contains { $0.kind == .route })
        XCTAssertEqual(clock.pendingTimerCount, waitingTimers, "the stall check must stop with the route")

        // Run well past the 6 s stall and the 5 s retry.
        let mark = hardware.calls.count
        clock.advance(by: 30)
        XCTAssertEqual(engine.state, .waiting)
        XCTAssertFalse(engine.isRetryScheduled)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark).filter { $0.involvesRoute }, [])
        XCTAssertTrue(hardware.aggregates.isEmpty)
        XCTAssertEqual(engine.routeStalls, 0)
        XCTAssertEqual(stallLogEntries(since: marker), [])

        assertShutdownLeavesNothing(engine, hardware)
    }

    // MARK: Edge cases

    func testDeviceEventsFromTheFailedStartsOwnAggregateDoNotBypassTheBackoff() throws {
        let hardware = FakeAudioHardware(devices: [mini, fx, fxFeeder], clock: clock)
        hardware.startResults = [kAudioHardwareUnspecifiedError]
        let engine = makeEngine(on: hardware)

        engine.setMode(.always)
        XCTAssertEqual(engine.state, .failed(kAudioHardwareUnspecifiedError))
        guard case .createAggregate(let failedAggregate, _)? = lifecycleCalls(hardware).first else {
            return XCTFail("the start must begin with the aggregate: \(lifecycleCalls(hardware))")
        }
        let failedRoute = IOProc(kind: .route, device: failedAggregate)
        let attempt: [Call] = [
            .createAggregate(failedAggregate, subDeviceUIDs: [mini.uid, fxFeeder.uid]),
            .createIOProc(failedRoute), .startIOProc(failedRoute),
            .destroyIOProc(failedRoute), .destroyAggregate(failedAggregate),
        ]
        XCTAssertEqual(lifecycleCalls(hardware), attempt)

        // The main queue delivers the device-list events of that create and destroy.
        clock.advance(by: 0)
        clock.advance(by: 4.9)
        XCTAssertEqual(lifecycleCalls(hardware), attempt, "no second attempt before 5 s")
        XCTAssertEqual(engine.state, .failed(kAudioHardwareUnspecifiedError))
        XCTAssertTrue(engine.isRetryScheduled)

        let mark = hardware.calls.count
        clock.advance(by: 0.1)
        XCTAssertEqual(engine.state, .running)
        let aggregate = try XCTUnwrap(hardware.aggregates.first)
        let route = IOProc(kind: .route, device: aggregate)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [
            .createAggregate(aggregate, subDeviceUIDs: [mini.uid, fxFeeder.uid]),
            .createIOProc(route), .startIOProc(route),
        ])

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testDeniedAccessOpensNothingAndRecheckingAfterAGrantStartsTheMode() throws {
        for mode in [MonitorEngine.Mode.auto, .always] {
            let hardware = FakeAudioHardware(devices: [seiren, fx, fxFeeder], clock: clock)
            let access = AccessStub(.denied)
            let engine = makeEngine(on: hardware, microphoneAccess: { access.value })

            engine.setMode(mode)
            clock.advance(by: 5)
            XCTAssertEqual(engine.state, .permissionDenied, "\(mode)")
            XCTAssertEqual(engine.activeSource, input(seiren, isSeiren: true), "\(mode)")
            XCTAssertFalse(engine.isStandbyRunning, "\(mode)")
            XCTAssertEqual(lifecycleCalls(hardware), [], "a denied mic must not be opened in \(mode)")

            access.value = .granted
            engine.recheckMicrophoneAccess()
            clock.advance(by: 0)
            switch mode {
            case .auto:
                let standby = IOProc(kind: .standby, device: seiren.id)
                XCTAssertEqual(engine.state, .waiting)
                XCTAssertEqual(lifecycleCalls(hardware), [.createIOProc(standby), .startIOProc(standby)])
                XCTAssertEqual(hardware.runningIOProcs, [standby])
            default:
                XCTAssertEqual(engine.state, .running)
                XCTAssertTrue(engine.isRoutingThroughFX)
                let aggregate = try XCTUnwrap(hardware.aggregates.first)
                XCTAssertEqual(hardware.runningIOProcs, [IOProc(kind: .route, device: aggregate)])
            }
            XCTAssertEqual(engine.mode, mode)

            assertShutdownLeavesNothing(engine, hardware)
        }
    }

    func testDefaultInputChangeWithoutASeirenMovesTheRouteToTheNewDefault() throws {
        let hardware = FakeAudioHardware(devices: [builtInMic, headset, fx, fxFeeder], clock: clock)
        hardware.defaultInputID = builtInMic.id
        hardware.recorders = [recorder(on: fx.id)]
        let engine = makeEngine(on: hardware)

        engine.setMode(.auto)
        XCTAssertEqual(engine.state, .running)
        XCTAssertEqual(engine.activeSource, input(builtInMic, isSeiren: false))
        XCTAssertEqual(lastAggregateSubDevices(hardware), [builtInMic.uid, fxFeeder.uid])
        let firstAggregate = try XCTUnwrap(hardware.aggregates.first)
        let firstRoute = IOProc(kind: .route, device: firstAggregate)

        let mark = hardware.calls.count
        hardware.defaultInputID = headset.id
        hardware.fireDefaultInputChanged()
        clock.advance(by: 3)

        XCTAssertEqual(engine.state, .running)
        XCTAssertEqual(engine.activeSource, input(headset, isSeiren: false))
        let secondAggregate = try XCTUnwrap(hardware.aggregates.first)
        let secondRoute = IOProc(kind: .route, device: secondAggregate)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [
            .stopIOProc(firstRoute), .destroyIOProc(firstRoute), .destroyAggregate(firstAggregate),
            .createAggregate(secondAggregate, subDeviceUIDs: [headset.uid, fxFeeder.uid]),
            .createIOProc(secondRoute), .startIOProc(secondRoute),
        ])
        XCTAssertEqual(hardware.runningIOProcs, [secondRoute])

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testWithoutPerProcessRecordingAutoRunsASeirenAlwaysAndUsesNoOtherMic() throws {
        // Before macOS 14 the engine cannot see which app records what.
        let hardware = FakeAudioHardware(devices: [builtInMic, fx, fxFeeder], clock: clock)
        hardware.recordingProcessesSupported = false
        hardware.recorders = [recorder(on: fx.id)]
        let engine = makeEngine(on: hardware)

        engine.setMode(.auto)
        clock.advance(by: 5)
        XCTAssertEqual(engine.state, .noDevice, "another mic needs positive recorder evidence")
        XCTAssertNil(engine.activeSource)
        XCTAssertFalse(engine.otherInputsSupported)
        XCTAssertEqual(lifecycleCalls(hardware), [])

        // With a Seiren, Auto runs the route like On - always, with no recorder seen.
        plug(seiren, into: hardware)
        XCTAssertEqual(engine.state, .running)
        XCTAssertEqual(engine.activeSource, input(seiren, isSeiren: true))
        XCTAssertTrue(engine.isRoutingThroughFX)
        let aggregate = try XCTUnwrap(hardware.aggregates.first)
        let route = IOProc(kind: .route, device: aggregate)
        XCTAssertTrue(hardware.runningIOProcs.contains(route))

        let mark = hardware.calls.count
        clock.advance(by: 10)
        XCTAssertEqual(engine.state, .running)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [], "auto polls must not stop the route")

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testRecorderOnStreamMixAloneStartsAutoOnlyWhenStreamMixIsATrigger() throws {
        let streamMix = Device(id: 22, uid: MonitorEngine.streamMixDeviceUID, name: "Seiren Stream Mix",
                               inputStreams: 1)
        let hardware = FakeAudioHardware(devices: [seiren, fx, fxFeeder, streamMix], clock: clock)
        hardware.recorders = [recorder(on: streamMix.id)]
        let engine = makeEngine(on: hardware)
        let standby = IOProc(kind: .standby, device: seiren.id)

        engine.setMode(.auto)
        hardware.fireRunningStateChanged(on: streamMix.id)
        clock.advance(by: 5)
        XCTAssertFalse(engine.includeStreamMixInTriggers)
        XCTAssertEqual(engine.state, .waiting)
        XCTAssertEqual(lifecycleCalls(hardware), [.createIOProc(standby), .startIOProc(standby)])

        let mark = hardware.calls.count
        engine.includeStreamMixInTriggers = true
        XCTAssertEqual(engine.state, .running)
        XCTAssertTrue(engine.isRoutingThroughFX)
        let aggregate = try XCTUnwrap(hardware.aggregates.first)
        let route = IOProc(kind: .route, device: aggregate)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [
            .createAggregate(aggregate, subDeviceUIDs: [seiren.uid, fxFeeder.uid]),
            .createIOProc(route), .startIOProc(route),
        ])
        XCTAssertEqual(hardware.runningIOProcs, [standby, route])

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testAudioServiceRestartWithTheSameDeviceIDsBuildsANewAggregateAndIOProc() throws {
        let hardware = FakeAudioHardware(devices: [seiren, fx, fxFeeder], clock: clock)
        let engine = makeEngine(on: hardware)
        engine.setMode(.always)
        XCTAssertEqual(engine.state, .running)
        let firstAggregate = try XCTUnwrap(hardware.aggregates.first)
        let firstRoute = IOProc(kind: .route, device: firstAggregate)

        // coreaudiod restarts: every device leaves and returns under the same
        // ID, and the private aggregate is gone. The restart can finish before
        // the main queue delivers its events, so the engine sees only the end.
        let mark = hardware.calls.count
        hardware.devices = [seiren, fx, fxFeeder]
        hardware.fireDevicesChanged()
        hardware.fireDevicesChanged()

        XCTAssertEqual(engine.state, .running)
        XCTAssertEqual(engine.activeSource, input(seiren, isSeiren: true))
        XCTAssertTrue(engine.isRoutingThroughFX)
        let secondAggregate = try XCTUnwrap(hardware.aggregates.first)
        XCTAssertNotEqual(secondAggregate, firstAggregate)
        let secondRoute = IOProc(kind: .route, device: secondAggregate)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [
            .stopIOProc(firstRoute), .destroyIOProc(firstRoute), .destroyAggregate(firstAggregate),
            .createAggregate(secondAggregate, subDeviceUIDs: [seiren.uid, fxFeeder.uid]),
            .createIOProc(secondRoute), .startIOProc(secondRoute),
        ])
        XCTAssertEqual(hardware.runningIOProcs, [secondRoute])

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testFailedRestartAfterASampleRateChangeFailsRetriesAndRecoversAfterFiveSeconds() throws {
        let hardware = FakeAudioHardware(devices: [seiren, fx, fxFeeder], clock: clock)
        let engine = makeEngine(on: hardware)
        engine.setMode(.always)
        XCTAssertEqual(engine.state, .running)
        let firstAggregate = try XCTUnwrap(hardware.aggregates.first)
        let firstRoute = IOProc(kind: .route, device: firstAggregate)
        let index = try XCTUnwrap(hardware.devices.firstIndex { $0.id == firstAggregate })

        var mark = hardware.calls.count
        hardware.startResults = [kAudioHardwareUnspecifiedError]
        hardware.devices[index].sampleRate = 96000
        hardware.fireSampleRateChanged(on: firstAggregate)

        XCTAssertEqual(engine.state, .failed(kAudioHardwareUnspecifiedError))
        XCTAssertTrue(engine.isRetryScheduled)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [
            .stopIOProc(firstRoute), .startIOProc(firstRoute),
            .stopIOProc(firstRoute), .destroyIOProc(firstRoute), .destroyAggregate(firstAggregate),
        ])
        XCTAssertTrue(hardware.ioProcs.isEmpty)

        mark = hardware.calls.count
        clock.advance(by: 4.9)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [], "no attempt before 5 s")
        XCTAssertEqual(engine.state, .failed(kAudioHardwareUnspecifiedError))

        clock.advance(by: 0.1)
        XCTAssertEqual(engine.state, .running)
        XCTAssertFalse(engine.isRetryScheduled)
        let secondAggregate = try XCTUnwrap(hardware.aggregates.first)
        let secondRoute = IOProc(kind: .route, device: secondAggregate)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [
            .createAggregate(secondAggregate, subDeviceUIDs: [seiren.uid, fxFeeder.uid]),
            .createIOProc(secondRoute), .startIOProc(secondRoute),
        ])
        XCTAssertEqual(hardware.runningIOProcs, [secondRoute])

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testStandbyStopsForGoodOnceThisProcessIsSeenRecordingTheSeiren() {
        let hardware = FakeAudioHardware(devices: [seiren, fx, fxFeeder], clock: clock)
        let engine = makeEngine(on: hardware)
        let standby = IOProc(kind: .standby, device: seiren.id)
        engine.setMode(.auto)
        XCTAssertTrue(engine.isStandbyRunning)
        XCTAssertEqual(lifecycleCalls(hardware), [.createIOProc(standby), .startIOProc(standby)])

        // With no route running, only standby can make this process record the Seiren.
        let mark = hardware.calls.count
        hardware.ownInputs = [seiren.id]
        clock.advance(by: 0.1)
        XCTAssertFalse(engine.isStandbyRunning)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [.stopIOProc(standby), .destroyIOProc(standby)])

        // The process stops recording, polls and a device event come and go.
        hardware.ownInputs = nil
        clock.advance(by: 10)
        hardware.fireDevicesChanged()
        XCTAssertFalse(engine.isStandbyRunning)
        XCTAssertEqual(engine.state, .waiting)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [.stopIOProc(standby), .destroyIOProc(standby)],
                       "standby must stay stopped")

        assertShutdownLeavesNothing(engine, hardware)
    }

    func testModeChangeDuringBackoffClearsTheFailureAndStartsAtOnce() {
        let hardware = FakeAudioHardware(devices: [seiren], clock: clock)
        hardware.startResults = [kAudioHardwareUnspecifiedError]
        hardware.recorders = [recorder(on: seiren.id)]
        let engine = makeEngine(on: hardware)
        let monitor = IOProc(kind: .monitor, device: seiren.id)

        engine.setMode(.always)
        XCTAssertEqual(engine.state, .failed(kAudioHardwareUnspecifiedError))
        XCTAssertTrue(engine.isRetryScheduled)

        clock.advance(by: 1)
        let mark = hardware.calls.count
        engine.setMode(.auto)
        XCTAssertEqual(engine.state, .running)
        XCTAssertNil(engine.startFailure)
        XCTAssertFalse(engine.isRetryScheduled)
        XCTAssertEqual(lifecycleCalls(hardware, since: mark), [.createIOProc(monitor), .startIOProc(monitor)])
        XCTAssertEqual(hardware.runningIOProcs, [monitor])

        assertShutdownLeavesNothing(engine, hardware)
    }

    // MARK: Helpers

    /// Logs a unique entry, so a test reads only the entries logged after it.
    private func logMarker() -> String {
        let marker = "scenario \(UUID().uuidString)"
        EventLog.shared.log(category: .system, message: "\(marker)")
        return marker
    }

    private func stallLogEntries(since marker: String) -> [String] {
        let recent = EventLog.shared.recent
        let start = recent.lastIndex { $0.message == marker } ?? recent.startIndex
        return recent[start...].filter { $0.category == .route && $0.message.hasPrefix("route stalled") }
            .map(\.message)
    }

    private func makeEngine(on hardware: FakeAudioHardware,
                            microphoneAccess: (@MainActor () -> MonitorEngine.MicrophoneAccess)? = nil)
        -> MonitorEngine {
        MonitorEngine(microphoneAccess: microphoneAccess, hardware: hardware, clock: clock)
    }

    @MainActor
    private final class AccessStub {
        var value: MonitorEngine.MicrophoneAccess
        init(_ value: MonitorEngine.MicrophoneAccess) { self.value = value }
    }

    private func input(_ device: Device, isSeiren: Bool) -> InputDevice {
        InputDevice(uid: device.uid, name: device.name, isSeiren: isSeiren)
    }

    private func recorder(on device: AudioObjectID) -> AudioDevices.RecordingProcess {
        AudioDevices.RecordingProcess(pid: 4242, bundleID: "us.zoom.xos", objectID: 900, inputDeviceIDs: [device])
    }

    private func unplug(_ device: Device, from hardware: FakeAudioHardware) {
        hardware.devices.removeAll { $0.uid == device.uid }
        hardware.fireDevicesChanged()
    }

    private func plug(_ device: Device, into hardware: FakeAudioHardware) {
        hardware.devices.append(device)
        hardware.fireDevicesChanged()
    }

    /// The calls that open, close, start or stop something, after the first
    /// `index` calls. Buffer sizes and stream usage are left out.
    private func lifecycleCalls(_ hardware: FakeAudioHardware, since index: Int = 0) -> [Call] {
        hardware.calls[index...].filter {
            switch $0 {
            case .setBufferFrameSize, .setStreamUsage: false
            default: true
            }
        }
    }

    private func lastAggregateSubDevices(_ hardware: FakeAudioHardware) -> [String]? {
        for call in hardware.calls.reversed() {
            if case .createAggregate(_, let subDeviceUIDs) = call { return subDeviceUIDs }
        }
        return nil
    }

    /// Shuts the engine down and checks that every IOProc, aggregate and
    /// listener it made is gone, and that each create was matched by one destroy.
    private func assertShutdownLeavesNothing(_ engine: MonitorEngine, _ hardware: FakeAudioHardware,
                                             file: StaticString = #filePath, line: UInt = #line) {
        engine.shutdown()
        // Deliver the events the shutdown queued; the engine must not act on them.
        let shutdownCalls = hardware.calls.count
        clock.advance(by: 0)
        XCTAssertEqual(lifecycleCalls(hardware, since: shutdownCalls), [], file: file, line: line)
        XCTAssertEqual(engine.state, .stopped, file: file, line: line)
        XCTAssertNil(engine.activeSource, file: file, line: line)
        XCTAssertTrue(hardware.ioProcs.isEmpty, "IOProcs left: \(hardware.ioProcs)", file: file, line: line)
        XCTAssertTrue(hardware.runningIOProcs.isEmpty, file: file, line: line)
        XCTAssertTrue(hardware.aggregates.isEmpty, "aggregates left: \(hardware.aggregates)", file: file, line: line)
        XCTAssertTrue(hardware.listenedProperties.isEmpty,
                      "listeners left: \(hardware.listenedProperties)", file: file, line: line)
        XCTAssertEqual(clock.pendingTimerCount, 0, "timers left", file: file, line: line)

        var createdProcs: [IOProc: Int] = [:]
        var destroyedProcs: [IOProc: Int] = [:]
        var createdAggregates: [AudioObjectID: Int] = [:]
        var destroyedAggregates: [AudioObjectID: Int] = [:]
        for call in hardware.calls {
            switch call {
            case .createIOProc(let proc): createdProcs[proc, default: 0] += 1
            case .destroyIOProc(let proc): destroyedProcs[proc, default: 0] += 1
            case .createAggregate(let id, _): createdAggregates[id, default: 0] += 1
            case .destroyAggregate(let id): destroyedAggregates[id, default: 0] += 1
            default: break
            }
        }
        XCTAssertFalse(createdProcs.isEmpty, "every scenario opens at least one IOProc", file: file, line: line)
        XCTAssertEqual(createdProcs, destroyedProcs, "IOProc creates and destroys", file: file, line: line)
        XCTAssertEqual(createdAggregates, destroyedAggregates, "aggregate creates and destroys", file: file, line: line)
    }
}

private extension FakeAudioHardware.Call {
    /// Whether this call acts on the FX route: its aggregate or its IOProc.
    var involvesRoute: Bool {
        switch self {
        case .createAggregate, .destroyAggregate: true
        case .createIOProc(let proc), .startIOProc(let proc), .stopIOProc(let proc), .destroyIOProc(let proc):
            proc.kind == .route
        case .setStreamUsage(let proc, _, _): proc.kind == .route
        case .setBufferFrameSize: false
        }
    }
}
