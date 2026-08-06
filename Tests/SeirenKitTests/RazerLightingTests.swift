import XCTest
@testable import SeirenKit

/// The report codec is verified byte-for-byte against real frames captured from
/// Razer Synapse 4 driving a Seiren V3 Pro (its middleware logs the full
/// `dataSend` buffer for every command). The leading `0x07` in each capture is
/// the HID report ID, which travels outside the 64-byte body we build.
final class RazerLightingTests: XCTestCase {

    /// Expand a captured 65-byte `dataSend` array into the 64-byte body.
    private func body(ofCapture capture: [UInt8]) -> [UInt8] {
        XCTAssertEqual(capture.first, 0x07, "captures start with the report ID")
        return Array(capture.dropFirst())
    }

    /// A captured frame, zero-padded to the full 65 bytes.
    private func padded(_ head: [UInt8], crc: UInt8) -> [UInt8] {
        var f = head + [UInt8](repeating: 0, count: 63 - head.count)
        f += [crc, 0]
        return f
    }

    // MARK: Golden vectors from Synapse 4 captures

    func testEncodesSetDeviceModeExactlyLikeSynapse() {
        // Synapse: "Set Device Mode" dataSend
        // [7,0,2,0,0,0,2,0,4,3,0,...,7,0]
        let captured = padded([7, 0, 2, 0, 0, 0, 2, 0, 4, 3, 0], crc: 7)
        let report = RazerCommand.setDeviceMode(3, txn: 2)
        XCTAssertEqual(report.encoded(), body(ofCapture: captured))
    }

    func testEncodesAudioCommandExactlyLikeSynapse() {
        // Synapse: "Set EQ Preset" (audio class 0x08) dataSend
        // [7,0,8,0,0,0,2,8,2,0,6,0,...,6,0]
        let captured = padded([7, 0, 8, 0, 0, 0, 2, 8, 2, 0, 6], crc: 6)
        let report = RazerReport(transactionId: 8, dataSize: 2,
                                 commandClass: 8, commandId: 2, args: [0, 6])
        XCTAssertEqual(report.encoded(), body(ofCapture: captured))
    }

    func testChecksumMatchesSynapseOnLongerArgs() {
        // Synapse: "Set HPF State" [7,0,17,0,0,0,2,8,21,0,3,...,13,0] and
        // "Set Parametric Band Status" [7,0,7,0,0,0,11,8,33,0*11,...,37,0].
        let hpf = RazerReport(transactionId: 17, dataSize: 2,
                              commandClass: 8, commandId: 21, args: [0, 3])
        XCTAssertEqual(hpf.encoded()[62], 13)

        let bands = RazerReport(transactionId: 7, dataSize: 11,
                                commandClass: 8, commandId: 33,
                                args: [UInt8](repeating: 0, count: 11))
        XCTAssertEqual(bands.encoded()[62], 37)
    }

    // MARK: Chroma command layout (from Synapse's lighting-engine source)

    func testCustomFrameSelectEffectMatchesSynapseArgs() {
        // Synapse selects the uploaded frame with effect args
        // [0, 0, CustomFrame=8, 0, 0, 0] and data size 6.
        let r = RazerCommand.setEffect(.customFrame, txn: 1)
        let e = r.encoded()
        XCTAssertEqual(e[5], 6)                      // data size
        XCTAssertEqual(e[6], 0x0F)                   // Chroma class
        XCTAssertEqual(e[7], 0x02)                   // Set Chroma Effect
        XCTAssertEqual(Array(e[8..<14]), [0, 0, 8, 0, 0, 0])
    }

    func testStaticEffectCarriesOneColor() {
        let r = RazerCommand.setEffect(.static, colors: [RGB(0, 255, 0)], txn: 5)
        let e = r.encoded()
        XCTAssertEqual(e[5], 9)                      // 6 + 3
        XCTAssertEqual(Array(e[8..<17]), [0, 0, 1, 0, 0, 1, 0, 255, 0])
    }

    func testCustomFrameRowLayoutForTheRing() {
        // generateChromaFrameData: [profile, region, row, start, end, rgb...],
        // data size 5 + 3n. The V3 Pro ring is row 0, cols 0...11.
        let ring = (0..<12).map { RGB(UInt8($0), 0, 0) }
        let r = RazerCommand.customFrameRow(ring, txn: 3)
        let e = r.encoded()
        XCTAssertEqual(e[5], 41)                     // 5 + 36
        XCTAssertEqual(e[6], 0x0F)
        XCTAssertEqual(e[7], 0x03)                   // Set Chroma Frame
        XCTAssertEqual(Array(e[8..<13]), [0, 0, 0, 0, 11])
        XCTAssertEqual(e[13], 0)                     // LED 0 red
        XCTAssertEqual(e[10 + 3 + 3 * 11], 11)       // LED 11 red channel
    }

    func testBrightnessScalesLikeSynapse() {
        // Synapse: floor(percent / 100 * 255).
        XCTAssertEqual(RazerCommand.setBrightness(percent: 100, txn: 1).args[2], 255)
        XCTAssertEqual(RazerCommand.setBrightness(percent: 50, txn: 1).args[2], 127)
        XCTAssertEqual(RazerCommand.setBrightness(percent: 0, txn: 1).args[2], 0)
        XCTAssertEqual(RazerCommand.setBrightness(percent: 999, txn: 1).args[2], 255)
    }

    // MARK: Reply parsing

    func testReplyParsing() {
        var body = [UInt8](repeating: 0, count: 64)
        body[0] = 0x02                               // success
        body[1] = 9
        body[5] = 2
        body[6] = 0
        body[7] = 0x81
        body[8] = 1; body[9] = 3                     // firmware v1.3
        let reply = RazerReport.Reply(body: body)
        XCTAssertNotNil(reply)
        XCTAssertTrue(reply!.isSuccess)
        XCTAssertEqual(reply!.transactionId, 9)
        XCTAssertEqual(reply!.args, [1, 3])

        XCTAssertNil(RazerReport.Reply(body: [0x02, 0x00]))
    }

    func testRGBHexParsing() {
        XCTAssertEqual(RGB(hex: "00FF00"), RGB(0, 255, 0))
        XCTAssertEqual(RGB(hex: "#1A2b3C"), RGB(0x1A, 0x2B, 0x3C))
        XCTAssertNil(RGB(hex: "12345"))
        XCTAssertNil(RGB(hex: "GGGGGG"))
        XCTAssertEqual(RGB(0x1A, 0x2B, 0x3C).hex, "1A2B3C")
    }
}
