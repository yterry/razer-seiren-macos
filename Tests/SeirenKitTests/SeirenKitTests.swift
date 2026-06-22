import XCTest
@testable import SeirenKit

final class SeirenKitTests: XCTestCase {
    func testV3ProRegistered() {
        let model = DeviceRegistry.all().first { $0.pid == 0x058E }
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.name, "Razer Seiren V3 Pro")
        XCTAssertEqual(model?.hidUsagePage, 0xFF53)   // Razer audio vendor page
    }

    func testV3ProMonitorNotYetCaptured() {
        // Honest pre-capture state: the transport is known, the bytes are not.
        let model = DeviceRegistry.builtins.first { $0.pid == 0x058E }
        XCTAssertEqual(model?.monitorSupported, false)
    }

    func testHexParseSpaced() {
        XCTAssertEqual(Hex.parse("02 80 07 00 00 50 41"),
                       [0x02, 0x80, 0x07, 0x00, 0x00, 0x50, 0x41])
    }

    func testHexParsePrefixedAndCommas() {
        XCTAssertEqual(Hex.parse("0x02, 0x80, 0xE1"), [0x02, 0x80, 0xE1])
    }

    func testHexParseRunTogether() {
        XCTAssertEqual(Hex.parse("028007"), [0x02, 0x80, 0x07])
    }

    func testCommandFrameBytesExcludeReportID() {
        let f = CommandFrame(reportID: 0x07, type: .feature, hex: "50 41 0E")
        XCTAssertEqual(f.bytes, [0x50, 0x41, 0x0E])
    }
}
