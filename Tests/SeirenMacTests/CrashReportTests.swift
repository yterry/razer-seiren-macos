import Foundation
import SeirenKit
import XCTest
@testable import seiren_mac

@MainActor
final class CrashReportTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeirenMacTests.CrashReportTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testReportIsOfferedUntilItHasBeenSeen() throws {
        let directory = try makeDirectory()
        let crashed = Date(timeIntervalSinceNow: -60)
        let report = directory.appendingPathComponent("seiren-mac-2026-11-14-090000.ips")
        try Data("{}".utf8).write(to: report)
        try FileManager.default.setAttributes([.modificationDate: crashed], ofItemAtPath: report.path)

        XCTAssertEqual(AppDelegate.unseenCrashReport(in: directory, seenAt: nil)?.lastPathComponent,
                       report.lastPathComponent)
        XCTAssertEqual(AppDelegate.unseenCrashReport(in: directory, seenAt: crashed.addingTimeInterval(-1))?
            .lastPathComponent, report.lastPathComponent)
        XCTAssertNil(AppDelegate.unseenCrashReport(in: directory, seenAt: Date()))
    }

    func testMissingDirectoryOffersNothingAndLogsOneEntry() throws {
        let missing = try makeDirectory().appendingPathComponent("DiagnosticReports", isDirectory: true)
        let before = EventLog.shared.recent

        XCTAssertNil(AppDelegate.unseenCrashReport(in: missing, seenAt: nil))

        let added = Array(EventLog.shared.recent.dropFirst(before.count))
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added.first?.category, .system)
        XCTAssertTrue(added.first?.message.hasPrefix("can't read crash reports") == true)
        XCTAssertFalse(added.first?.message.contains(missing.path) == true)
    }
}
