import XCTest
@testable import SeirenKit

/// Hardware-free tests for MonitorEngine's observable contract. They run on CI
/// (no Seiren attached): we match on a name that can't exist so setting a mode
/// resolves to `.noDevice` deterministically rather than depending on hardware.
@MainActor
final class MonitorEngineTests: XCTestCase {

    func testInitialStateIsStoppedAndOff() {
        let engine = MonitorEngine(deviceNameMatch: "no-such-device-xyzzy")
        XCTAssertEqual(engine.state, .stopped)
        XCTAssertEqual(engine.mode, .off)
        XCTAssertNil(engine.connectedDeviceName)
    }

    func testAlwaysWithNoMatchingDeviceReportsNoDevice() {
        let engine = MonitorEngine(deviceNameMatch: "no-such-device-xyzzy")
        engine.setMode(.always)
        XCTAssertEqual(engine.mode, .always)     // desired intent recorded…
        XCTAssertEqual(engine.state, .noDevice)  // …actual state honest
        XCTAssertNil(engine.connectedDeviceName)
        engine.shutdown()
    }

    func testAutoWithNoMatchingDeviceReportsNoDevice() {
        let engine = MonitorEngine(deviceNameMatch: "no-such-device-xyzzy")
        engine.setMode(.auto)
        XCTAssertEqual(engine.mode, .auto)
        XCTAssertEqual(engine.state, .noDevice)
        engine.shutdown()
    }

    func testOffReturnsToStopped() {
        let engine = MonitorEngine(deviceNameMatch: "no-such-device-xyzzy")
        engine.setMode(.always)
        engine.setMode(.off)
        XCTAssertEqual(engine.mode, .off)
        XCTAssertEqual(engine.state, .stopped)
        XCTAssertNil(engine.connectedDeviceName)
    }

    func testLevelClampsToUnitRange() {
        let engine = MonitorEngine(deviceNameMatch: "no-such-device-xyzzy")
        engine.level = 2.0
        XCTAssertEqual(engine.level, 1.0, accuracy: 0.0001)
        engine.level = -1.0
        XCTAssertEqual(engine.level, 0.0, accuracy: 0.0001)
        engine.level = 0.42
        XCTAssertEqual(engine.level, 0.42, accuracy: 0.0001)
    }

    func testModeRawValuesRoundTrip() {
        // The app persists Mode.rawValue in UserDefaults — keep it stable.
        for m in [MonitorEngine.Mode.off, .always, .auto] {
            XCTAssertEqual(MonitorEngine.Mode(rawValue: m.rawValue), m)
        }
    }

    func testDelegateFiresOnStateChange() {
        let engine = MonitorEngine(deviceNameMatch: "no-such-device-xyzzy")
        let spy = DelegateSpy()
        engine.delegate = spy
        engine.setMode(.always)   // off/stopped -> always/noDevice is a change
        XCTAssertGreaterThan(spy.changeCount, 0)
        engine.shutdown()
    }

    private final class DelegateSpy: MonitorEngineDelegate {
        var changeCount = 0
        func monitorEngineDidChange(_ engine: MonitorEngine) { changeCount += 1 }
    }
}
