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

    // MARK: Device selection (pure; no hardware)

    private typealias Candidate = MonitorEngine.Candidate

    func testSelectDeviceAcceptsInputOnlyMic() {
        // The V3 Mini has no headphone jack: input streams only. It must still
        // be chosen, or the app never sees the mic at all.
        let mini = Candidate(id: 7, name: "Razer Seiren V3 Mini", hasInput: true, hasOutput: false)
        XCTAssertEqual(MonitorEngine.selectDevice(from: [mini], match: "seiren"), mini)
    }

    func testSelectDeviceRejectsOutputOnlyDevice() {
        // A microphone with no input stream isn't a microphone (e.g. the
        // output half of a UAC device macOS splits in two).
        let outOnly = Candidate(id: 3, name: "Razer Seiren X", hasInput: false, hasOutput: true)
        XCTAssertNil(MonitorEngine.selectDevice(from: [outOnly], match: "seiren"))
    }

    func testSelectDevicePrefersFullDuplexOverInputOnly() {
        // With a headphone-equipped mic and a jack-less one both attached, the
        // one that can monitor wins - whichever order Core Audio lists them.
        let mini = Candidate(id: 1, name: "Razer Seiren V3 Mini", hasInput: true, hasOutput: false)
        let pro = Candidate(id: 2, name: "Razer Seiren V3 Pro", hasInput: true, hasOutput: true)
        XCTAssertEqual(MonitorEngine.selectDevice(from: [mini, pro], match: "seiren"), pro)
        XCTAssertEqual(MonitorEngine.selectDevice(from: [pro, mini], match: "seiren"), pro)
    }

    func testSelectDeviceMatchesNameCaseInsensitively() {
        let mini = Candidate(id: 1, name: "RAZER SEIREN V3 MINI", hasInput: true, hasOutput: false)
        let other = Candidate(id: 2, name: "MacBook Pro Microphone", hasInput: true, hasOutput: false)
        XCTAssertEqual(MonitorEngine.selectDevice(from: [other, mini], match: "Seiren"), mini)
        XCTAssertNil(MonitorEngine.selectDevice(from: [other], match: "seiren"))
    }

    func testSelectDeviceIgnoresOurOwnVirtualDevices() {
        // "Seiren FX" and the "Seiren Voice" aggregate both contain "seiren"
        // and are full-duplex; with the real mic unplugged they must not be
        // adopted as the Seiren (the app would then "monitor" its own loopback
        // and never report "No Seiren detected").
        let fx = Candidate(id: 5, name: "Seiren FX", hasInput: true, hasOutput: true, isVirtual: true)
        let agg = Candidate(id: 6, name: "Seiren Voice", hasInput: true, hasOutput: true, isVirtual: true)
        XCTAssertNil(MonitorEngine.selectDevice(from: [fx, agg], match: "seiren"))

        // …and a full-duplex virtual device must not outrank the real,
        // input-only mic either.
        let mini = Candidate(id: 7, name: "Razer Seiren V3 Mini", hasInput: true, hasOutput: false)
        XCTAssertEqual(MonitorEngine.selectDevice(from: [fx, agg, mini], match: "seiren"), mini)
    }

    func testHeadphoneOutputDefaultsToTrueUntilAMicIsMatched() {
        // The V3 Pro case is the default, so existing UI (volume slider) is
        // unchanged until an input-only mic is actually matched.
        let engine = MonitorEngine(deviceNameMatch: "no-such-device-xyzzy")
        XCTAssertTrue(engine.deviceHasHeadphoneOutput)
        engine.setMode(.always)
        XCTAssertTrue(engine.deviceHasHeadphoneOutput)
        engine.shutdown()
    }

    private final class DelegateSpy: MonitorEngineDelegate {
        var changeCount = 0
        func monitorEngineDidChange(_ engine: MonitorEngine) { changeCount += 1 }
    }
}
