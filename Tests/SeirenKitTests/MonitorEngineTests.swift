import XCTest
@testable import SeirenKit

/// Hardware-free tests for MonitorEngine's observable contract. They run on CI
/// and on a developer's Mac with FX installed: a non-matching name plus disabled
/// fallback makes mode changes resolve to `.noDevice` on either machine.
@MainActor
final class MonitorEngineTests: XCTestCase {

    func testInitialStateIsStoppedAndOff() {
        let engine = MonitorEngine(deviceNameMatch: "no-such-device-xyzzy", fallbackEnabled: false)
        defer { engine.shutdown() }
        XCTAssertEqual(engine.state, .stopped)
        XCTAssertEqual(engine.mode, .off)
        XCTAssertEqual(engine.inputPreference, .automatic)
        XCTAssertFalse(engine.includeStreamMixInTriggers)
        XCTAssertNil(engine.activeSource)
    }

    func testAlwaysWithNoMatchingDeviceReportsNoDevice() {
        let engine = MonitorEngine(deviceNameMatch: "no-such-device-xyzzy", fallbackEnabled: false)
        defer { engine.shutdown() }
        engine.setMode(.always)
        XCTAssertEqual(engine.mode, .always)     // desired intent recorded…
        XCTAssertEqual(engine.state, .noDevice)  // …actual state honest
        XCTAssertNil(engine.activeSource)
    }

    func testAutoWithNoMatchingDeviceReportsNoDevice() {
        let engine = MonitorEngine(deviceNameMatch: "no-such-device-xyzzy", fallbackEnabled: false)
        defer { engine.shutdown() }
        engine.setMode(.auto)
        XCTAssertEqual(engine.mode, .auto)
        XCTAssertEqual(engine.state, .noDevice)
    }

    func testOffReturnsToStopped() {
        let engine = MonitorEngine(deviceNameMatch: "no-such-device-xyzzy", fallbackEnabled: false)
        defer { engine.shutdown() }
        engine.setMode(.always)
        engine.setMode(.off)
        XCTAssertEqual(engine.mode, .off)
        XCTAssertEqual(engine.state, .stopped)
        XCTAssertNil(engine.activeSource)
    }

    func testLevelClampsToUnitRange() {
        let engine = MonitorEngine(deviceNameMatch: "no-such-device-xyzzy", fallbackEnabled: false)
        defer { engine.shutdown() }
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
        let engine = MonitorEngine(deviceNameMatch: "no-such-device-xyzzy", fallbackEnabled: false)
        defer { engine.shutdown() }
        let spy = DelegateSpy()
        engine.delegate = spy
        engine.setMode(.always)   // off/stopped -> always/noDevice is a change
        XCTAssertGreaterThan(spy.changeCount, 0)
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
        let engine = MonitorEngine(deviceNameMatch: "no-such-device-xyzzy", fallbackEnabled: false)
        defer { engine.shutdown() }
        XCTAssertTrue(engine.deviceHasHeadphoneOutput)
        engine.setMode(.always)
        XCTAssertTrue(engine.deviceHasHeadphoneOutput)
    }

    private func mic(_ id: UInt32, _ name: String, output: Bool = false,
                     builtIn: Bool = false, virtual: Bool = false, input: Bool = true,
                     uid: String? = nil) -> Candidate {
        Candidate(id: id, uid: uid ?? "mic-\(id)", name: name, hasInput: input,
                  hasOutput: output, isVirtual: virtual, isBuiltIn: builtIn)
    }

    private func choose(_ devices: [Candidate], preference: MonitorEngine.InputPreference = .automatic,
                        defaultUID: String? = nil, fx: Bool = true) -> MonitorEngine.Source? {
        MonitorEngine.selectSource(from: devices, preference: preference,
                                   defaultInputUID: defaultUID, match: "seiren", fxInstalled: fx)
    }

    func testAutomaticUsesSeirenBeforeDefaultOrBuiltIn() {
        let builtIn = mic(1, "Mac mic", builtIn: true)
        let seiren = mic(2, "Razer Seiren Mini")
        XCTAssertEqual(choose([builtIn, seiren], defaultUID: builtIn.uid)?.device, seiren)
        XCTAssertEqual(choose([builtIn, seiren])?.isSeiren, true)
        XCTAssertEqual(choose([builtIn])?.isSeiren, false)
        XCTAssertEqual(choose([builtIn, seiren], fx: false)?.device, seiren)
    }

    func testFallbackOrderIsDefaultThenBuiltInThenFirstEligible() {
        let usb = mic(1, "Webcam"), builtIn = mic(2, "Mac mic", builtIn: true)
        XCTAssertEqual(choose([usb, builtIn], defaultUID: usb.uid)?.device, usb)
        XCTAssertEqual(choose([usb, builtIn], defaultUID: "missing")?.device, builtIn)
        XCTAssertEqual(choose([usb])?.device, usb)
        XCTAssertNil(choose([usb, builtIn], fx: false))
        XCTAssertNil(choose([]))
    }

    func testEveryOwnUIDAndVirtualTransportIsIneligibleEvenWhenPinnedOrDefault() {
        let builtIn = mic(1, "Mac mic", builtIn: true)
        let excluded = [
            mic(2, "Seiren FX", uid: MonitorEngine.fxDeviceUID),
            mic(3, "Seiren Stream Mix", uid: MonitorEngine.streamMixDeviceUID),
            mic(4, "Seiren Voice", uid: MonitorEngine.aggregateUID),
            mic(5, "Seiren aggregate", virtual: true),
            mic(6, "Virtual microphone", virtual: true),
            mic(7, "Seiren speakers", output: true, input: false),
        ]
        for device in excluded {
            XCTAssertFalse(device.isEligible)
            XCTAssertEqual(choose([device, builtIn], defaultUID: device.uid)?.device, builtIn)
            XCTAssertEqual(choose([device, builtIn], preference: .device(uid: device.uid))?.device, builtIn)
            XCTAssertNil(MonitorEngine.selectDevice(from: [device], match: "seiren"))
        }
    }

    func testPinnedEligibleDeviceOverridesAutomaticAndMissingPinFallsBack() {
        let usb = mic(1, "Headset", output: true), seiren = mic(2, "Razer SEIREN")
        XCTAssertEqual(choose([seiren, usb], preference: .device(uid: usb.uid))?.device, usb)
        XCTAssertEqual(choose([seiren], preference: .device(uid: usb.uid))?.device, seiren)
        XCTAssertEqual(choose([usb], preference: .device(uid: "missing"))?.device, usb)
        XCTAssertEqual(choose([seiren, usb], preference: .device(uid: usb.uid), fx: false)?.device, seiren)
        XCTAssertNil(choose([usb], preference: .device(uid: usb.uid), fx: false))
        XCTAssertEqual(choose([seiren], preference: .device(uid: seiren.uid), fx: false)?.device, seiren)
    }

    func testAutomaticSwitchesBackWhenSeirenReturnsAndPrefersFullDuplex() {
        let usb = mic(1, "Webcam"), mini = mic(2, "Seiren Mini")
        let pro = mic(3, "Seiren Pro", output: true)
        XCTAssertEqual(choose([usb])?.device, usb)
        XCTAssertEqual(choose([usb, mini])?.device, mini)
        XCTAssertEqual(choose([usb, mini, pro])?.device, pro)
        XCTAssertEqual(choose([pro, mini], preference: .device(uid: mini.uid))?.device, mini)
    }

    func testRunPolicyTable() {
        let mini = MonitorEngine.Source(device: mic(1, "Seiren"), isSeiren: true)
        let pro = MonitorEngine.Source(device: mic(1, "Seiren", output: true), isSeiren: true)
        let fallback = MonitorEngine.Source(device: mic(2, "Headset", output: true), isSeiren: false)
        func policy(_ mode: MonitorEngine.Mode, _ source: MonitorEngine.Source?,
                    fx: Bool = true, recording: Set<UInt32> = [], mix: Bool = false) -> MonitorEngine.State {
            MonitorEngine.runPolicy(mode: mode, source: source, fxInstalled: fx,
                                    recordingDevices: recording, fxDeviceID: 10,
                                    streamMixDeviceID: 11, includeStreamMixInTriggers: mix)
        }
        for mode in [MonitorEngine.Mode.off, .always, .auto] {
            XCTAssertEqual(policy(mode, nil), mode == .off ? .stopped : .noDevice)
            XCTAssertEqual(policy(mode, mini, fx: false), mode == .off ? .stopped : .needsFX)
        }
        XCTAssertEqual(policy(.off, pro, recording: [1, 10, 11], mix: true), .stopped)
        XCTAssertEqual(policy(.always, pro, fx: false), .running)
        XCTAssertEqual(policy(.always, mini), .running)
        XCTAssertEqual(policy(.auto, pro), .waiting)
        XCTAssertEqual(policy(.auto, pro, recording: [1]), .running)
        XCTAssertEqual(policy(.auto, pro, fx: false, recording: [1]), .running)
        XCTAssertEqual(policy(.auto, mini), .waiting)
        XCTAssertEqual(policy(.auto, mini, recording: [10]), .running)
        XCTAssertEqual(policy(.auto, pro, recording: [99]), .waiting)
        XCTAssertEqual(policy(.auto, pro, fx: false, recording: [10]), .waiting)
        for mode in [MonitorEngine.Mode.always, .auto] {
            XCTAssertEqual(policy(mode, fallback), .waiting)
            XCTAssertEqual(policy(mode, fallback, recording: [2]), .waiting)
            XCTAssertEqual(policy(mode, fallback, recording: [10]), .running,
                           "Unplugging Seiren during a call must keep FX fed by the fallback")
            XCTAssertEqual(policy(mode, fallback, recording: [11]), .waiting)
            XCTAssertEqual(policy(mode, fallback, recording: [11], mix: true), .running)
        }
        XCTAssertEqual(policy(.auto, pro, recording: [11]), .waiting)
        XCTAssertEqual(policy(.auto, pro, recording: [11], mix: true), .running)
    }

    private final class DelegateSpy: MonitorEngineDelegate {
        var changeCount = 0
        func monitorEngineDidChange(_ engine: MonitorEngine) { changeCount += 1 }
    }
}
