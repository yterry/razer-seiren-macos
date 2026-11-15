import XCTest
import CoreAudio
@testable import SeirenKit

/// Runs the whole engine on `FakeAudioHardware`: the path from a hardware
/// event through reconciliation to IOProcs, aggregates and state, which the
/// policy-function tests do not reach and which needs no audio device here.
@MainActor
final class MonitorEngineFakeHardwareTests: XCTestCase {
    private typealias Device = FakeAudioHardware.Device
    private typealias IOProc = FakeAudioHardware.IOProc

    private let seiren = Device(id: 10, uid: "seiren-uid", name: "Razer Seiren V3 Pro",
                                inputStreams: 1, outputStreams: 1)
    private let fx = Device(id: 20, uid: MonitorEngine.fxDeviceUID, name: "Seiren FX", inputStreams: 1)
    private let fxFeeder = Device(id: 21, uid: MonitorEngine.fxFeederUID, name: "Seiren FX Feeder",
                                  outputStreams: 1, isHidden: true)

    override func tearDown() async throws {
        // Starting a route sets the globals the RT procs read; restore the
        // defaults other tests assume.
        gMonitorEnabled = true
        gMonitorOutBuffers = 1
        try await super.tearDown()
    }

    private func makeEngine(on hardware: FakeAudioHardware) -> MonitorEngine {
        MonitorEngine(hardware: hardware, clock: FakeClock())
    }

    func testSeirenAppearingInAlwaysModeStartsTheMonitor() {
        let hardware = FakeAudioHardware()
        let engine = makeEngine(on: hardware)
        defer { engine.shutdown() }
        engine.setMode(.always)
        XCTAssertEqual(engine.state, .noDevice)
        XCTAssertTrue(hardware.ioProcs.isEmpty)

        hardware.devices.append(seiren)
        hardware.fireDevicesChanged()

        XCTAssertEqual(engine.state, .running)
        XCTAssertEqual(engine.activeSource,
                       MonitorEngine.InputDevice(uid: seiren.uid, name: seiren.name, isSeiren: true))
        XCTAssertFalse(engine.isRoutingThroughFX)
        XCTAssertEqual(hardware.runningIOProcs, [IOProc(kind: .monitor, device: seiren.id)])
    }

    func testSeirenDisappearingTearsDownAndReportsNoDevice() {
        let hardware = FakeAudioHardware(devices: [seiren])
        let engine = makeEngine(on: hardware)
        defer { engine.shutdown() }
        engine.setMode(.always)
        let monitor = IOProc(kind: .monitor, device: seiren.id)
        XCTAssertEqual(engine.state, .running)
        XCTAssertEqual(hardware.runningIOProcs, [monitor])

        hardware.devices.removeAll { $0.id == seiren.id }
        hardware.fireDevicesChanged()

        XCTAssertEqual(engine.state, .noDevice)
        XCTAssertNil(engine.activeSource)
        XCTAssertTrue(hardware.calls.contains(.stopIOProc(monitor)))
        XCTAssertTrue(hardware.ioProcs.isEmpty, "the IOProc must be destroyed, not only stopped")
        XCTAssertFalse(hardware.listenedProperties.contains(.sampleRate(seiren.id)))
    }

    func testSeirenFXDeviceIDChangeRestartsTheRoute() throws {
        let hardware = FakeAudioHardware(devices: [seiren, fx, fxFeeder])
        let engine = makeEngine(on: hardware)
        defer { engine.shutdown() }
        engine.setMode(.always)
        XCTAssertEqual(engine.state, .running)
        XCTAssertTrue(engine.isRoutingThroughFX)
        let firstAggregate = try XCTUnwrap(hardware.aggregates.first)
        XCTAssertEqual(hardware.runningIOProcs, [IOProc(kind: .route, device: firstAggregate)])

        // A coreaudiod restart brings the driver's devices back under new IDs.
        for index in hardware.devices.indices where [fx.id, fxFeeder.id].contains(hardware.devices[index].id) {
            hardware.devices[index].id += 10
        }
        hardware.fireDevicesChanged()

        XCTAssertEqual(engine.state, .running)
        XCTAssertTrue(engine.isRoutingThroughFX)
        XCTAssertEqual(hardware.aggregates.count, 1, "the first aggregate must be destroyed")
        let secondAggregate = try XCTUnwrap(hardware.aggregates.first)
        XCTAssertNotEqual(secondAggregate, firstAggregate)
        XCTAssertEqual(hardware.ioProcs, [IOProc(kind: .route, device: secondAggregate)])
        XCTAssertEqual(hardware.runningIOProcs, [IOProc(kind: .route, device: secondAggregate)])
        XCTAssertEqual(hardware.calls.last { if case .createAggregate = $0 { true } else { false } },
                       .createAggregate(secondAggregate, subDeviceUIDs: [seiren.uid, fxFeeder.uid]))
    }
}
