import CoreAudio
@testable import SeirenKit
import XCTest

final class DiagnosticsReportTests: XCTestCase {
    private func device(_ name: String, uid: String, transport: UInt32, inputs: Int = 1,
                        outputs: Int = 0) -> DiagnosticsSnapshot.Device {
        DiagnosticsSnapshot.Device(uid: uid, name: name, transport: transport, inputStreams: inputs,
                                   outputStreams: outputs, sampleRate: 48000)
    }

    private func snapshot(devices: [DiagnosticsSnapshot.Device] = [], history: [String] = [],
                          activeSource: MonitorEngine.InputDevice? = nil,
                          inputPreference: MonitorEngine.InputPreference = .automatic,
                          mixerState: MixerEngine.State = .off) -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            versions: .init(app: "1.2.0", macOS: "Version 15.1 (Build 24B83)", architecture: "arm64",
                            installedFX: "1.1.0", bundledFX: "1.2.0", reinstallOffered: false, updateOffered: true),
            engine: .init(mode: .auto, state: .running, inputPreference: inputPreference,
                          activeSource: activeSource, routesThroughFX: true, standbyRunning: false,
                          route: .init(callbacks: 1200, inputBuffers: 2, outputBuffers: 3, monitorBuffers: 1,
                                       inputPeak: 0.5, sampleRate: 48000),
                          recordingBundleIDs: ["us.zoom.xos"]),
            devices: devices,
            mixer: .init(enabled: true, availability: .idle, state: mixerState, channelCount: 3,
                         diagnostics: .init(callbacks: 10, inputBuffers: 2, outputBuffers: 1,
                                            inputPeaks: [0.5, 0], channelPeaks: [0.25, 0, 0],
                                            mixOutputPeak: 0.5, sampleRate: 48000,
                                            taps: [.init(channelName: "Desktop audio", processCount: 2)])),
            lighting: .init(attachedModel: "Seiren V3 Pro", deviceConnected: true, lastError: nil),
            microphoneAccess: "authorized", inputMonitoringAccess: "granted", history: history)
    }

    func testStartsWithReviewLineAndListsSectionsInOrder() {
        let report = DiagnosticsReport.render(snapshot())
        XCTAssertTrue(report.hasPrefix("Seiren diagnostics - review before posting\n"))
        let lines = report.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let sections = ["Versions", "Engine", "Devices", "Mixer", "Lighting", "Permissions", "History"]
        let positions = sections.map { lines.firstIndex(of: $0) }
        XCTAssertFalse(positions.contains(nil), "\(positions)")
        XCTAssertEqual(positions.compactMap { $0 }, positions.compactMap { $0 }.sorted())
        XCTAssertTrue(report.contains("  Recording apps: us.zoom.xos"))
        XCTAssertTrue(report.contains("  No event history recorded."))
    }

    func testOtherDevicesAreListedByTransportInsteadOfName() {
        let airpods = device("Alex's AirPods", uid: "AA-BB-CC-DD-EE-FF:input",
                             transport: kAudioDeviceTransportTypeBluetooth)
        let report = DiagnosticsReport.render(snapshot(
            devices: [
                device("Razer Seiren V3 Pro", uid: "AppleUSBAudioEngine:Razer:Seiren:SN0042:1",
                       transport: kAudioDeviceTransportTypeUSB, outputs: 1),
                device("MacBook Pro Microphone", uid: "BuiltInMicrophoneDevice",
                       transport: kAudioDeviceTransportTypeBuiltIn),
                airpods,
                device("Alex's USB Mic", uid: "AppleUSBAudioEngine:Acme:Mic:SN9:1",
                       transport: kAudioDeviceTransportTypeUSB),
                device("Seiren FX", uid: MonitorEngine.fxDeviceUID, transport: kAudioDeviceTransportTypeVirtual,
                       inputs: 1, outputs: 0),
            ],
            activeSource: .init(uid: airpods.uid, name: airpods.name, isSeiren: false),
            inputPreference: .device(uid: airpods.uid)))

        XCTAssertFalse(report.contains("Alex"))
        XCTAssertFalse(report.contains("SN0042"))
        XCTAssertFalse(report.contains("AA-BB-CC"))
        XCTAssertTrue(report.contains("  Razer Seiren V3 Pro: USB, 1 in / 1 out streams, 48000 Hz, Seiren"))
        XCTAssertTrue(report.contains("  Built-in input: Built-in"))
        XCTAssertTrue(report.contains("  Bluetooth input 1: Bluetooth"))
        XCTAssertTrue(report.contains("  USB input 1: USB"))
        XCTAssertTrue(report.contains("  Seiren FX: Virtual, 1 in / 0 out streams, 48000 Hz, Seiren FX"))
        XCTAssertTrue(report.contains("  Input preference: Pinned: Bluetooth input 1"))
        XCTAssertTrue(report.contains("  Active source: Bluetooth input 1"))
    }

    func testAggregateOrVirtualDeviceNamedSeirenIsListedByTransport() {
        let aggregate = device("Alex's Seiren + AirPods", uid: "alex-aggregate",
                               transport: kAudioDeviceTransportTypeAggregate, outputs: 1)
        let report = DiagnosticsReport.render(snapshot(
            devices: [aggregate,
                      device("Alex's Seiren Loopback", uid: "alex-loopback",
                             transport: kAudioDeviceTransportTypeVirtual)],
            activeSource: .init(uid: "unlisted", name: "Alex's Seiren Mic", isSeiren: true)))

        XCTAssertFalse(report.contains("Alex"))
        XCTAssertTrue(report.contains("  Aggregate input and output 1: Aggregate, 1 in / 1 out streams, 48000 Hz\n"))
        XCTAssertTrue(report.contains("  Virtual input 1: Virtual, 1 in / 0 out streams, 48000 Hz\n"))
        XCTAssertTrue(report.contains("  Active source: an unlisted input"))
    }

    func testReportContainsNoHomeDirectoryPath() {
        let report = DiagnosticsReport.render(snapshot(
            devices: [device("/Users/alex/Seiren Loopback", uid: "loop",
                             transport: kAudioDeviceTransportTypeUSB)],
            history: ["Opened /Users/alex/Applications/Seiren.app", "Driver at /Users/alex/Library/Audio"]))
        XCTAssertFalse(report.contains("/Users/"))
        XCTAssertFalse(report.contains("alex"))
        XCTAssertTrue(report.contains("Opened ~/Applications/Seiren.app"))
    }

    func testTenDevicesAndFullHistoryStayUnder200Lines() {
        let devices = (0..<10).map {
            device("Interface \($0)", uid: "usb-\($0)", transport: kAudioDeviceTransportTypeUSB,
                   inputs: 1, outputs: 1)
        }
        let history = (0..<300).map { "event \($0)" }
        let report = DiagnosticsReport.render(snapshot(devices: devices, history: history, mixerState: .running))
        let lines = report.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertLessThan(lines.count, 200)
        XCTAssertTrue(report.contains("  Taps: Desktop audio (2 processes)"))
        XCTAssertFalse(report.contains("  event 199\n"))
        XCTAssertTrue(report.contains("  event 200\n"))
        XCTAssertTrue(report.contains("  event 299\n"))
    }

    func testVersionLine() {
        XCTAssertEqual(DiagnosticsReport.versionLine(app: "1.2.0", installedFX: "1.1.0"),
                       "Seiren 1.2.0 · Seiren FX 1.1.0")
        XCTAssertEqual(DiagnosticsReport.versionLine(app: "1.2.0", installedFX: nil),
                       "Seiren 1.2.0 · Seiren FX not installed")
    }
}
