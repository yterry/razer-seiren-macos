import Foundation
import SeirenKit
import XCTest
@testable import seiren_mac

final class LocalizableStringsTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Every key in `Strings.swift` with its English value, read from the source.
    private func tableEntries() throws -> [String: String] {
        let source = try String(contentsOf: Self.root.appendingPathComponent("Sources/seiren-mac/Strings.swift"),
                                encoding: .utf8)
        let call = try NSRegularExpression(pattern:
            #"NSLocalizedString\("([^"]+)", bundle: \.main, value: "((?:[^"\\]|\\.)*)", comment: "#)
        let matches = call.matches(in: source, range: NSRange(source.startIndex..., in: source))
        // A call written another way would be skipped here and go unchecked.
        XCTAssertEqual(matches.count, source.components(separatedBy: "NSLocalizedString(").count - 1)
        var entries: [String: String] = [:]
        for match in matches {
            let key = String(source[Range(match.range(at: 1), in: source)!])
            let value = unescape(String(source[Range(match.range(at: 2), in: source)!]))
            if let earlier = entries[key] {
                XCTAssertEqual(earlier, value, "\(key) has two different values in the table")
            }
            entries[key] = value
        }
        return entries
    }

    /// The value of a Swift string literal; only the escapes the table uses.
    private func unescape(_ literal: String) -> String {
        var result = ""
        var iterator = literal.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else { result.append(character); continue }
            switch iterator.next() {
            case "n": result.append("\n")
            case "\"": result.append("\"")
            case "\\": result.append("\\")
            case let other: XCTFail("unsupported escape \\\(other.map(String.init) ?? "") in Strings.swift")
            }
        }
        return result
    }

    func testStringsFileHoldsEveryKeyInTheTableWithTheSameValue() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Resources/en.lproj/Localizable.strings"))
        let file = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        let table = try tableEntries()
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
