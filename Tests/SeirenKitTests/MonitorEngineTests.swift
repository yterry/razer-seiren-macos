import XCTest
import CoreAudio
import SeirenDSP
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
                     uid: String? = nil, terminal: UInt32? = kAudioStreamTerminalTypeMicrophone) -> Candidate {
        Candidate(id: id, uid: uid ?? "mic-\(id)", name: name, hasInput: input,
                  hasOutput: output, isVirtual: virtual, isBuiltIn: builtIn, inputTerminalType: terminal)
    }

    private func choose(_ devices: [Candidate], preference: MonitorEngine.InputPreference = .automatic,
                        defaultUID: String? = nil, fx: Bool = true,
                        otherInputsSupported: Bool = true) -> MonitorEngine.Source? {
        MonitorEngine.selectSource(from: devices, preference: preference,
                                   defaultInputUID: defaultUID, match: "seiren", fxInstalled: fx,
                                   otherInputsSupported: otherInputsSupported)
    }

    func testAutomaticUsesSeirenBeforeDefaultOrBuiltIn() {
        let builtIn = mic(1, "Mac mic", builtIn: true)
        let seiren = mic(2, "Razer Seiren Mini")
        XCTAssertEqual(choose([builtIn, seiren], defaultUID: builtIn.uid)?.device, seiren)
        XCTAssertEqual(choose([builtIn, seiren])?.isSeiren, true)
        XCTAssertEqual(choose([builtIn])?.isSeiren, false)
        XCTAssertEqual(choose([builtIn, seiren], fx: false)?.device, seiren)
    }

    func testFallbackOrderIsDefaultThenBuiltInThenFirstMicrophone() {
        let usb = mic(1, "Webcam"), builtIn = mic(2, "Mac mic", builtIn: true)
        XCTAssertEqual(choose([usb, builtIn], defaultUID: usb.uid)?.device, usb)
        XCTAssertEqual(choose([usb, builtIn], defaultUID: "missing")?.device, builtIn)
        XCTAssertEqual(choose([usb])?.device, usb)
        XCTAssertNil(choose([usb, builtIn], fx: false))
        XCTAssertNil(choose([]))
    }

    func testOtherInputsRequirePerProcessRecordingSupport() {
        let usb = mic(1, "Headset"), builtIn = mic(2, "Mac mic", builtIn: true)
        let seiren = mic(3, "Seiren")
        for preference in [MonitorEngine.InputPreference.automatic, .device(uid: usb.uid)] {
            XCTAssertNil(choose([usb, builtIn], preference: preference, defaultUID: usb.uid,
                                otherInputsSupported: false))
            XCTAssertEqual(choose([usb, builtIn, seiren], preference: preference,
                                  defaultUID: usb.uid, otherInputsSupported: false)?.device, seiren)
        }
        XCTAssertEqual(choose([seiren], preference: .device(uid: seiren.uid), fx: false,
                              otherInputsSupported: false)?.device, seiren)
    }

    func testLastAutomaticFallbackRequiresMicrophoneTerminal() {
        let line = mic(1, "Capture card", terminal: kAudioStreamTerminalTypeLine)
        let unknown = mic(2, "Unknown input", terminal: nil)
        let fx = mic(3, "Seiren FX", uid: MonitorEngine.fxDeviceUID)
        let terminals: [UInt32] = [kAudioStreamTerminalTypeMicrophone,
                                   kAudioStreamTerminalTypeHeadsetMicrophone,
                                   kAudioStreamTerminalTypeReceiverMicrophone]
        for terminal in terminals {
            let microphone = mic(4, "USB mic", terminal: terminal)
            XCTAssertEqual(choose([line, unknown, microphone], defaultUID: fx.uid)?.device, microphone)
        }
        for terminal in [kAudioStreamTerminalTypeLine, kAudioStreamTerminalTypeHDMI,
                         kAudioStreamTerminalTypeDigitalAudioInterface, kAudioStreamTerminalTypeUnknown] {
            let input = mic(5, "Non-microphone input", terminal: terminal)
            XCTAssertNil(choose([input], defaultUID: fx.uid))
        }
        XCTAssertNil(choose([line, unknown, fx], defaultUID: fx.uid))
        // The default and a pin are explicit choices and can still use a line input.
        XCTAssertEqual(choose([line], defaultUID: line.uid)?.device, line)
        XCTAssertEqual(choose([line], preference: .device(uid: line.uid))?.device, line)
        let builtIn = mic(6, "Built-in input", builtIn: true, terminal: nil)
        XCTAssertEqual(choose([line, builtIn])?.device, builtIn)
    }

    func testStartRetryBackoffTable() {
        for result in [MonitorEngine.State.failed(-1), .permissionDenied] {
            let failure = MonitorEngine.StartFailure.recording(result: result, sourceID: 1,
                                                                fxDeviceID: 10, now: 100)
            XCTAssertNotNil(failure)
            let cases: [(UInt32, UInt32?, TimeInterval, Bool)] = [
                (1, 10, 100, false), (1, 10, 104.999, false),
                (1, 10, 105, true), (1, 10, 106, true),
                (2, 10, 100, true), (1, 11, 100, true), (1, nil, 100, true),
            ]
            for (source, fx, now, expected) in cases {
                XCTAssertEqual(MonitorEngine.shouldRetryStart(sourceID: source, fxDeviceID: fx,
                                                               failure: failure, now: now), expected)
            }
        }
        let cleared = MonitorEngine.StartFailure.recording(result: .running, sourceID: 1,
                                                            fxDeviceID: 10, now: 101)
        XCTAssertNil(cleared)
        XCTAssertTrue(MonitorEngine.shouldRetryStart(sourceID: 1, fxDeviceID: 10,
                                                     failure: cleared, now: 101))
        let directFailure = MonitorEngine.StartFailure.recording(result: .failed(-1), sourceID: 1,
                                                                  fxDeviceID: nil, now: 100)
        XCTAssertFalse(MonitorEngine.shouldRetryStart(sourceID: 1, fxDeviceID: nil,
                                                      failure: directFailure, now: 104))
        XCTAssertTrue(MonitorEngine.shouldRetryStart(sourceID: 1, fxDeviceID: 10,
                                                     failure: directFailure, now: 100))
    }

    func testPollPreservesFailuresOnlyWhenWaiting() {
        for current in [MonitorEngine.State.failed(-1), .permissionDenied, .needsFX] {
            XCTAssertEqual(MonitorEngine.reconciledState(decision: .waiting, current: current,
                                                        fromPoll: true), current)
            XCTAssertEqual(MonitorEngine.reconciledState(decision: .running, current: current,
                                                        fromPoll: true), .running)
            XCTAssertEqual(MonitorEngine.reconciledState(decision: .stopped, current: current,
                                                        fromPoll: true), .stopped)
            XCTAssertEqual(MonitorEngine.reconciledState(decision: .noDevice, current: current,
                                                        fromPoll: true), .noDevice)
            XCTAssertEqual(MonitorEngine.reconciledState(decision: .waiting, current: current,
                                                        fromPoll: false), .waiting)
        }
        XCTAssertEqual(MonitorEngine.reconciledState(decision: .waiting, current: .running,
                                                    fromPoll: true), .waiting)
    }

    func testRecorderAbsenceKeepsRouteRunningWithinGrace() {
        let present = MonitorEngine.debouncedRunDecision(
            decision: .running, current: .running, recorderDriven: true, routeMatches: true, absenceSince: nil, now: 100)
        XCTAssertEqual(present.state, .running)
        XCTAssertNil(present.absenceSince)
        let absent = MonitorEngine.debouncedRunDecision(
            decision: .waiting, current: present.state, recorderDriven: true, routeMatches: true,
            absenceSince: present.absenceSince, now: 101)
        XCTAssertEqual(absent.state, .running)
        XCTAssertEqual(absent.absenceSince, 101)
        let stillAbsent = MonitorEngine.debouncedRunDecision(
            decision: .waiting, current: absent.state, recorderDriven: true, routeMatches: true,
            absenceSince: absent.absenceSince, now: 101.999)
        XCTAssertEqual(stillAbsent.state, .running)
        XCTAssertEqual(stillAbsent.absenceSince, 101)
    }

    func testRecorderAbsenceStopsAtOrAfterGrace() {
        for now in [101.0, 101.5, 105] {
            let result = MonitorEngine.debouncedRunDecision(
                decision: .waiting, current: .running, recorderDriven: true, routeMatches: true, absenceSince: 100, now: now)
            XCTAssertEqual(result.state, .waiting)
        }
    }

    func testRecorderPresenceClearsAbsenceAndNextAbsenceStartsNewGrace() {
        let present = MonitorEngine.debouncedRunDecision(
            decision: .running, current: .running, recorderDriven: true, routeMatches: true, absenceSince: 100, now: 100.5)
        XCTAssertNil(present.absenceSince)
        let absent = MonitorEngine.debouncedRunDecision(
            decision: .waiting, current: present.state, recorderDriven: true, routeMatches: true,
            absenceSince: present.absenceSince, now: 102)
        XCTAssertEqual(absent.state, .running)
        XCTAssertEqual(absent.absenceSince, 102)
    }

    func testOtherStopReasonsBypassRecorderGrace() {
        for decision in [MonitorEngine.State.stopped, .noDevice, .needsFX, .permissionDenied, .failed(-1)] {
            let result = MonitorEngine.debouncedRunDecision(
                decision: decision, current: .running, recorderDriven: true, routeMatches: true, absenceSince: 100, now: 100.1)
            XCTAssertEqual(result.state, decision)
            XCTAssertNil(result.absenceSince)
        }
        let alwaysToAuto = MonitorEngine.debouncedRunDecision(
            decision: .waiting, current: .running, recorderDriven: false, routeMatches: true,
            absenceSince: nil, now: 100)
        XCTAssertEqual(alwaysToAuto.state, .waiting)
        XCTAssertNil(alwaysToAuto.absenceSince)
        // A changed source / FX identity or a dead aggregate cannot retain the route.
        let changed = MonitorEngine.debouncedRunDecision(
            decision: .waiting, current: .running, recorderDriven: true, routeMatches: false, absenceSince: 100, now: 100.1)
        XCTAssertEqual(changed.state, .waiting)
        XCTAssertNil(changed.absenceSince)
        for current in [MonitorEngine.State.waiting, .stopped, .failed(-1), .permissionDenied] {
            let idle = MonitorEngine.debouncedRunDecision(
                decision: .waiting, current: current, recorderDriven: true, routeMatches: true, absenceSince: nil, now: 100)
            XCTAssertEqual(idle.state, .waiting)
            XCTAssertNil(idle.absenceSince)
        }
    }

    func testStandbyRequiresAutoSeirenOutputsFXAndHostPermission() {
        let pro = MonitorEngine.Source(device: mic(1, "Seiren Pro", output: true), isSeiren: true)
        let mini = MonitorEngine.Source(device: mic(2, "Seiren Mini"), isSeiren: true)
        let other = MonitorEngine.Source(device: mic(3, "Headset", output: true), isSeiren: false)
        XCTAssertTrue(MonitorEngine.shouldRunStandby(mode: .auto, source: pro, fxInstalled: true, allowed: true))
        for mode in [MonitorEngine.Mode.off, .always] {
            XCTAssertFalse(MonitorEngine.shouldRunStandby(mode: mode, source: pro, fxInstalled: true, allowed: true))
        }
        for source in [nil, mini, other] {
            XCTAssertFalse(MonitorEngine.shouldRunStandby(mode: .auto, source: source, fxInstalled: true, allowed: true))
        }
        XCTAssertFalse(MonitorEngine.shouldRunStandby(mode: .auto, source: pro, fxInstalled: false, allowed: true))
        XCTAssertFalse(MonitorEngine.shouldRunStandby(mode: .auto, source: pro, fxInstalled: true, allowed: false))
    }

    func testStandbyHostPermissionAndShutdownWithNoDevice() {
        let engine = MonitorEngine(deviceNameMatch: "no-such-device-xyzzy", fallbackEnabled: false)
        engine.setMode(.auto)
        XCTAssertFalse(engine.isStandbyRunning)
        engine.setStandbyAllowed(false)
        XCTAssertFalse(engine.isStandbyRunning)
        XCTAssertEqual(engine.state, .noDevice)
        engine.setStandbyAllowed(true)
        XCTAssertFalse(engine.isStandbyRunning)
        engine.shutdown()
        engine.setStandbyAllowed(false)
        engine.setStandbyAllowed(true)
        XCTAssertFalse(engine.isStandbyRunning)
        XCTAssertEqual(engine.state, .stopped)
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

    func testSampleRateChangesRepublishEQAndResetItsHistory() {
        let engine = MonitorEngine(deviceNameMatch: "no-such-device-xyzzy", fallbackEnabled: false)
        defer {
            engine.setEQEnabled(false)
            engine.configureSampleRate(48000)
            engine.shutdown()
        }
        let band = EQBand(type: .lowpass, freq: 3000)
        engine.setEQPreset(EQPreset(name: "Low pass", bands: [band]))
        engine.setEQEnabled(true)
        for rate in [48000.0, 16000, 96000, 44100, 48000] {
            engine.configureSampleRate(rate)
            XCTAssertEqual(engine.routeDiagnostics.sampleRate, rate)
            XCTAssertEqual(engine.studioAvailable, rate == 48000 || rate == 96000)
            var impulse: [Float] = [0.5, 0, 0, 0]
            impulse.withUnsafeMutableBufferPointer { seiren_dsp_process_mono($0.baseAddress, 4, 1) }
            // The first impulse sample exposes the published coefficients and
            // any stale filter history left by the preceding sample rate.
            let b0 = EQCoefficients.biquad(band, sampleRate: rate)![0]
            XCTAssertEqual(impulse[0], 0.5 * b0, accuracy: 0.00001)
        }
    }

    func testSampleRateChangesKeepGateAttackAtThreeMilliseconds() {
        let engine = MonitorEngine(deviceNameMatch: "no-such-device-xyzzy", fallbackEnabled: false)
        defer {
            engine.setNoiseSuppression(.off)
            engine.configureSampleRate(48000)
            engine.shutdown()
        }
        engine.setNoiseSuppression(.gate)
        for rate in [48000.0, 96000, 16000, 44100, 48000] {
            engine.configureSampleRate(rate)
            let frames = Int(rate * 0.003)
            var samples = [Float](repeating: 0.5, count: frames)
            samples.withUnsafeMutableBufferPointer {
                seiren_dsp_gate($0.baseAddress, Int32(frames), 1)
            }
            // One time constant should reach 1 - exp(-1) at every rate.
            XCTAssertEqual(samples.last!, 0.5 * (1 - exp(-1)), accuracy: 0.001)
        }
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
