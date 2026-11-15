import XCTest
import CoreAudio
@testable import SeirenKit

/// The plug, unplug, sleep, wake and driver-restart sequences users hit,
/// run end to end on `FakeAudioHardware` and `FakeClock`. Each test checks
/// the engine state, the active source, and the hardware calls, then shuts
/// the engine down and checks that nothing is left behind in the fake.
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
        let hardware = FakeAudioHardware(devices: [seiren])
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
        let hardware = FakeAudioHardware(devices: [builtInMic, headset, seiren, fx, fxFeeder])
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
        let hardware = FakeAudioHardware(devices: [seiren, headset, fx, fxFeeder])
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

    func testTwoSeirensPreferTheFullDuplexOneAndFallBackToTheInputOnlyOne() throws {
        // The input-only Seiren is listed first, so order alone would pick it.
        let hardware = FakeAudioHardware(devices: [mini, seiren, fx, fxFeeder])
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
        let hardware = FakeAudioHardware(devices: [mini])
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
        let hardware = FakeAudioHardware(devices: [seiren, fx, fxFeeder])
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
        let hardware = FakeAudioHardware(devices: [seiren])
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
        let hardware = FakeAudioHardware(devices: [seiren, fx, fxFeeder])
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
        let hardware = FakeAudioHardware(devices: [seiren, fx, fxFeeder])
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
        let hardware = FakeAudioHardware(devices: [seiren, fx, fxFeeder])
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

    // MARK: Helpers

    private func makeEngine(on hardware: FakeAudioHardware) -> MonitorEngine {
        MonitorEngine(hardware: hardware, clock: clock)
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
        XCTAssertEqual(engine.state, .stopped, file: file, line: line)
        XCTAssertNil(engine.activeSource, file: file, line: line)
        XCTAssertTrue(hardware.ioProcs.isEmpty, "IOProcs left: \(hardware.ioProcs)", file: file, line: line)
        XCTAssertTrue(hardware.runningIOProcs.isEmpty, file: file, line: line)
        XCTAssertTrue(hardware.aggregates.isEmpty, "aggregates left: \(hardware.aggregates)", file: file, line: line)
        XCTAssertTrue(hardware.listenedProperties.isEmpty,
                      "listeners left: \(hardware.listenedProperties)", file: file, line: line)

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
