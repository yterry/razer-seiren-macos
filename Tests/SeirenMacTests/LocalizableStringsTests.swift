import Foundation
import SeirenKit
import XCTest
@testable import seiren_mac

final class LocalizableStringsTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func strings(at url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
                             "\(url.path) is not a strings table")
    }

    /// Every key in `Strings.swift` with its English value, as Xcode's genstrings extracts it.
    private func extractedTable() throws -> [String: String] {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let genstrings = Process()
        genstrings.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        genstrings.arguments = ["genstrings", "-o", output.path,
                                Self.root.appendingPathComponent("Sources/seiren-mac/Strings.swift").path]
        try genstrings.run()
        genstrings.waitUntilExit()
        XCTAssertEqual(genstrings.terminationStatus, 0, "xcrun genstrings failed")
        return try strings(at: output.appendingPathComponent("Localizable.strings"))
    }

    func testStringsFileHoldsEveryKeyInTheTableWithTheSameValue() throws {
        let file = try strings(at: Self.root.appendingPathComponent("Resources/en.lproj/Localizable.strings"))
        let table = try extractedTable()
        XCTAssertGreaterThan(table.count, 100)
        for (key, value) in table.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(file[key], value, "Localizable.strings: \(key)")
        }
        XCTAssertEqual(Set(file.keys).subtracting(table.keys), [], "keys in Localizable.strings but not in the table")
    }

    func testVersionLine() {
        XCTAssertEqual(Strings.versionLine(app: "1.2.0", installedFX: "1.1.0"), "Seiren 1.2.0 · Seiren FX 1.1.0")
        XCTAssertEqual(Strings.versionLine(app: "1.2.0", installedFX: nil), "Seiren 1.2.0 · Seiren FX not installed")
    }

    /// The table names built-in presets and channels for display only, so what
    /// is saved and matched stays the English identifier.
    func testDisplayNamesOfStoredIdentifiers() {
        XCTAssertEqual(EQPreset.builtIns.map(Strings.eqPresetName), ["Flat", "Podcast", "Studio", "Broadcast"])
        XCTAssertEqual(MixerEngine.defaultChannels.map(Strings.mixerChannelName), ["Voice", "Desktop audio"])
        XCTAssertEqual(Strings.mixerChannelName(MixerEngine.Channel(source: .app(bundleID: "com.example.music"),
                                                                    name: "Music", level: 1)), "Music")
    }
}
