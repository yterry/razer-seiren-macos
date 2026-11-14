import CoreAudio
@testable import SeirenKit
import XCTest

@MainActor
final class EventLogTests: XCTestCase {
    func testRecentKeepsTheLatestEntriesOldestFirst() {
        let log = EventLog()
        for index in 0..<(EventLog.capacity + 10) {
            log.log(category: .route, message: "event \(index)")
        }

        XCTAssertEqual(EventLog.capacity, 300)
        XCTAssertEqual(log.recent.map(\.message), (10..<(EventLog.capacity + 10)).map { "event \($0)" })
        XCTAssertEqual(log.recent.map(\.category), Array(repeating: .route, count: EventLog.capacity))
    }

    func testDebugLinesStayOutOfRecent() {
        let log = EventLog()
        log.debug(category: .auto, message: "poll")
        log.log(category: .auto, message: "recorder present")

        XCTAssertEqual(log.recent.map(\.message), ["recorder present"])
    }

    func testRecentHidesNamesOfOtherDevices() {
        let log = EventLog()
        let headset = DiagnosticsSnapshot.Device(uid: "BT-1", name: "Alex's AirPods", transport: kAudioDeviceTransportTypeBluetooth,
                                                 inputStreams: 1, outputStreams: 1, sampleRate: 24000)
        let seiren = DiagnosticsSnapshot.Device(uid: "USB-1", name: "Razer Seiren V3 Pro", transport: kAudioDeviceTransportTypeUSB,
                                                inputStreams: 1, outputStreams: 1, sampleRate: 48000)
        log.log(category: .devices, message: "added: \(device: headset)")
        log.log(category: .devices, message: "added: \(device: seiren)")

        XCTAssertEqual(log.recent.map(\.message), [
            "added: <private> (Bluetooth, 1 in / 1 out streams)",
            "added: Razer Seiren V3 Pro (USB, 1 in / 1 out streams)",
        ])
    }
}
