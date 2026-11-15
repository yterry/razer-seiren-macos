@testable import SeirenKit
import XCTest

final class DriverCheckTests: XCTestCase {
    private let rates: [ClosedRange<Double>] = [44100...44100, 48000...48000, 88200...88200, 96000...96000]

    private func microphone() -> DriverCheck.Device {
        DriverCheck.Device(isHidden: false, inputStreamChannels: [2], outputStreamChannels: [],
                           canBeDefaultOutput: false, sampleRates: rates)
    }

    private func feeder() -> DriverCheck.Device {
        DriverCheck.Device(isHidden: true, inputStreamChannels: [], outputStreamChannels: [2],
                           canBeDefaultOutput: false, sampleRates: rates)
    }

    /// What the 3.0 driver publishes.
    private func installed() -> [String: DriverCheck.Device?] {
        ["SeirenFX:Device:0": microphone(), "SeirenFX:StreamMix": microphone(),
         "SeirenFX:Feeder:0": feeder(), "SeirenFX:StreamMix:Feeder": feeder()]
    }

    func testThreePointOhDriverPassesAndPrintsEveryDevice() {
        XCTAssertEqual(DriverCheck.failures(installed()), [])
        XCTAssertEqual(DriverCheck.table(installed()), """
            UID                        hidden  inputs    outputs   default output  sample rates (kHz)
            SeirenFX:Device:0          no      1 (2 ch)  0         no              44.1, 48, 88.2, 96
            SeirenFX:StreamMix         no      1 (2 ch)  0         no              44.1, 48, 88.2, 96
            SeirenFX:Feeder:0          yes     0         1 (2 ch)  no              44.1, 48, 88.2, 96
            SeirenFX:StreamMix:Feeder  yes     0         1 (2 ch)  no              44.1, 48, 88.2, 96
            """)
    }

    func testMissingDriverFailsForEveryDevice() {
        XCTAssertEqual(DriverCheck.failures([:]), [
            "SeirenFX:Device:0: not in the system device list",
            "SeirenFX:StreamMix: not in the system device list",
            "SeirenFX:Feeder:0: does not resolve through kAudioHardwarePropertyTranslateUIDToDevice",
            "SeirenFX:StreamMix:Feeder: does not resolve through kAudioHardwarePropertyTranslateUIDToDevice",
        ])
        let rows = DriverCheck.table([:]).split(separator: "\n").dropFirst()
        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows.allSatisfy { $0.hasSuffix("missing") }, "\(rows)")
    }

    /// The 2.0 driver had two visible duplex devices and no feeders.
    func testTwoPointOhDriverFails() {
        let duplex = DriverCheck.Device(isHidden: false, inputStreamChannels: [2], outputStreamChannels: [2],
                                        canBeDefaultOutput: true, sampleRates: rates)
        XCTAssertEqual(DriverCheck.failures(["SeirenFX:Device:0": duplex, "SeirenFX:StreamMix": duplex]), [
            "SeirenFX:Device:0: output streams 1 (2 ch), expected 0",
            "SeirenFX:Device:0: can become the default output device",
            "SeirenFX:StreamMix: output streams 1 (2 ch), expected 0",
            "SeirenFX:StreamMix: can become the default output device",
            "SeirenFX:Feeder:0: does not resolve through kAudioHardwarePropertyTranslateUIDToDevice",
            "SeirenFX:StreamMix:Feeder: does not resolve through kAudioHardwarePropertyTranslateUIDToDevice",
        ])
    }

    func testHiddenFlagMustMatchTheDeviceRole() {
        var devices = installed()
        devices["SeirenFX:StreamMix"] = DriverCheck.Device(
            isHidden: true, inputStreamChannels: [2], outputStreamChannels: [],
            canBeDefaultOutput: false, sampleRates: rates)
        devices["SeirenFX:Feeder:0"] = DriverCheck.Device(
            isHidden: false, inputStreamChannels: [], outputStreamChannels: [2],
            canBeDefaultOutput: false, sampleRates: rates)
        XCTAssertEqual(DriverCheck.failures(devices), [
            "SeirenFX:StreamMix: is hidden, expected visible",
            "SeirenFX:Feeder:0: is visible, expected hidden",
        ])
    }

    func testStreamAndChannelCountsMustMatch() {
        var devices = installed()
        devices["SeirenFX:Device:0"] = DriverCheck.Device(
            isHidden: false, inputStreamChannels: [1], outputStreamChannels: [],
            canBeDefaultOutput: false, sampleRates: rates)
        devices["SeirenFX:StreamMix:Feeder"] = DriverCheck.Device(
            isHidden: true, inputStreamChannels: [2], outputStreamChannels: [2, 2],
            canBeDefaultOutput: false, sampleRates: rates)
        XCTAssertEqual(DriverCheck.failures(devices), [
            "SeirenFX:Device:0: input streams 1 (1 ch), expected 1 (2 ch)",
            "SeirenFX:StreamMix:Feeder: input streams 1 (2 ch), expected 0",
            "SeirenFX:StreamMix:Feeder: output streams 2 (2 ch, 2 ch), expected 1 (2 ch)",
        ])
    }

    func testFeederThatCanBeDefaultOutputFails() {
        var devices = installed()
        devices["SeirenFX:Feeder:0"] = DriverCheck.Device(
            isHidden: true, inputStreamChannels: [], outputStreamChannels: [2],
            canBeDefaultOutput: true, sampleRates: rates)
        XCTAssertEqual(DriverCheck.failures(devices), ["SeirenFX:Feeder:0: can become the default output device"])
    }

    func testEveryRequiredSampleRateMustBeAvailable() {
        var devices = installed()
        devices["SeirenFX:StreamMix"] = DriverCheck.Device(
            isHidden: false, inputStreamChannels: [2], outputStreamChannels: [],
            canBeDefaultOutput: false, sampleRates: [48000...48000, 96000...96000])
        XCTAssertEqual(DriverCheck.failures(devices), ["SeirenFX:StreamMix: sample rates missing 44.1, 88.2 kHz"])
    }

    func testContinuousRateRangeCoversRequiredRates() {
        var devices = installed()
        devices["SeirenFX:Device:0"] = DriverCheck.Device(
            isHidden: false, inputStreamChannels: [2], outputStreamChannels: [],
            canBeDefaultOutput: false, sampleRates: [8000...192000])
        XCTAssertEqual(DriverCheck.failures(devices), [])
        XCTAssertTrue(DriverCheck.table(devices).contains("SeirenFX:Device:0          no      1 (2 ch)  0         no              8-192"))
    }
}
