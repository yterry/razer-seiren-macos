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

    func testV3ProHasChromaLighting() {
        let model = DeviceRegistry.builtins.first { $0.pid == 0x058E }
        XCTAssertEqual(model?.chromaLighting, true)
    }

    func testV3MiniRegisteredWithoutChromaLighting() {
        // The V3 Mini: input-only audio, a red/green mute LED, and a Razer
        // control report on a different vendor page (0xFF07) that nothing in
        // the app may write to.
        let model = DeviceRegistry.all().first { $0.pid == 0x056A }
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.name, "Razer Seiren V3 Mini")
        XCTAssertEqual(model?.hidUsagePage, 0xFF07)
        XCTAssertEqual(model?.chromaLighting, false)
        XCTAssertEqual(model?.monitorSupported, false)
    }

    func testChromaLightingDefaultsToFalseWhenAbsentFromJSON() throws {
        // A contributed devices/*.json that predates the capability flag must
        // not silently opt its model into the lighting send path.
        let legacy = """
        {"name": "Razer Seiren Something", "pid": 1234, "hidUsagePage": 65363,
         "commands": {"monitorOn": null, "monitorOff": null, "handshake": null}}
        """
        let model = try JSONDecoder().decode(DeviceModel.self, from: Data(legacy.utf8))
        XCTAssertFalse(model.chromaLighting)
        XCTAssertEqual(model.commands, CommandTable())

        let explicit = """
        {"name": "X", "pid": 1, "hidUsagePage": 2, "chromaLighting": true}
        """
        XCTAssertTrue(try JSONDecoder().decode(DeviceModel.self, from: Data(explicit.utf8)).chromaLighting)
    }

    func testChromaLightingRoundTripsThroughJSON() throws {
        let original = DeviceRegistry.builtins.first { $0.pid == 0x056A }!
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(DeviceModel.self, from: data), original)
    }

    func testRepoDeviceFilesMatchBuiltins() throws {
        // devices/*.json is the contributor-facing copy of the registry; keep
        // the two from drifting on identity and capabilities.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("devices")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let model = try JSONDecoder().decode(DeviceModel.self, from: Data(contentsOf: file))
            let builtin = DeviceRegistry.builtins.first { $0.pid == model.pid }
            XCTAssertNotNil(builtin, "\(file.lastPathComponent) has no built-in counterpart")
            XCTAssertEqual(model.name, builtin?.name, file.lastPathComponent)
            XCTAssertEqual(model.hidUsagePage, builtin?.hidUsagePage, file.lastPathComponent)
            XCTAssertEqual(model.chromaLighting, builtin?.chromaLighting, file.lastPathComponent)
        }
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
