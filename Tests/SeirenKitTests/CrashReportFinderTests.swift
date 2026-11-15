import Foundation
import SeirenKit
import XCTest

final class CrashReportFinderTests: XCTestCase {
    private var directory: URL!
    private let lastSeen = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeirenKitTests.CrashReportFinderTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let directory = directory!
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// Writes a report file modified `offset` seconds after `lastSeen`.
    @discardableResult
    private func writeReport(_ name: String, secondsAfterLastSeen offset: TimeInterval) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("report \(name)".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: lastSeen.addingTimeInterval(offset)],
                                              ofItemAtPath: url.path)
        return url
    }

    private func newest() throws -> String? {
        try CrashReportFinder.newestReport(in: directory, processName: "seiren-mac", after: lastSeen)?
            .lastPathComponent
    }

    func testNoReportsFindsNothing() throws {
        XCTAssertNil(try newest())
    }

    func testReportFromBeforeTheLastSeenTimeIsIgnored() throws {
        try writeReport("seiren-mac-2026-11-01-090000.ips", secondsAfterLastSeen: -60)
        XCTAssertNil(try newest())
    }

    func testReportFromAfterTheLastSeenTimeIsFound() throws {
        try writeReport("seiren-mac-2026-11-14-090000.ips", secondsAfterLastSeen: 60)
        XCTAssertEqual(try newest(), "seiren-mac-2026-11-14-090000.ips")
    }

    func testOlderCrashFileFormatIsFound() throws {
        try writeReport("seiren-mac_2026-11-14-090000_Mac.crash", secondsAfterLastSeen: 60)
        XCTAssertEqual(try newest(), "seiren-mac_2026-11-14-090000_Mac.crash")
    }

    func testNewestOfTwoNewReportsWins() throws {
        // Names in the opposite order from their dates, so only the date can pick the right one.
        try writeReport("seiren-mac-b.ips", secondsAfterLastSeen: 60)
        try writeReport("seiren-mac-a.ips", secondsAfterLastSeen: 120)
        XCTAssertEqual(try newest(), "seiren-mac-a.ips")
    }

    func testFilesForOtherProcessesAndOtherKindsAreIgnored() throws {
        try writeReport("seiren-probe-2026-11-14-090000.ips", secondsAfterLastSeen: 60)
        try writeReport("Finder-2026-11-14-090000.ips", secondsAfterLastSeen: 60)
        try writeReport("seiren-mac-2026-11-14-090000.diag", secondsAfterLastSeen: 60)
        try writeReport("seiren-mac_2026-11-14-090000.hang", secondsAfterLastSeen: 60)
        XCTAssertNil(try newest())
    }

    func testMissingDirectoryThrows() throws {
        let missing = directory.appendingPathComponent("missing", isDirectory: true)
        XCTAssertThrowsError(try CrashReportFinder.newestReport(in: missing, processName: "seiren-mac",
                                                                after: lastSeen))
    }

    func testUnreadableDirectoryThrows() throws {
        try writeReport("seiren-mac-2026-11-14-090000.ips", secondsAfterLastSeen: 60)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try newest())
    }
}
