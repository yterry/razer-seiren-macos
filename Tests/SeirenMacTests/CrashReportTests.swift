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

    /// A throwaway suite stored in its own temporary directory, never the standard domain.
    private func makeSettings() throws -> Settings {
        let directory = try makeDirectory()
        let suiteName = directory.appendingPathComponent("defaults").path
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        return Settings(defaults)
    }

    private func writeReport(in directory: URL, modified: Date) throws -> URL {
        let report = directory.appendingPathComponent("seiren-mac-2026-11-14-090000.ips")
        try Data("{}".utf8).write(to: report)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: report.path)
        return report
    }

    func testReportIsOfferedUntilItHasBeenSeen() throws {
        let directory = try makeDirectory()
        let settings = try makeSettings()
        let crashed = Date(timeIntervalSinceNow: -60)
        let report = try writeReport(in: directory, modified: crashed)

        settings.crashReportSeenAt = crashed.addingTimeInterval(-1)
        XCTAssertEqual(AppDelegate.unseenCrashReport(in: directory, settings: settings)?.lastPathComponent,
                       report.lastPathComponent)
        settings.crashReportSeenAt = Date()
        XCTAssertNil(AppDelegate.unseenCrashReport(in: directory, settings: settings))
    }

    func testFirstLaunchWithoutSeenTimeOffersOlderReportNeverAndStoresLaunchTime() throws {
        let directory = try makeDirectory()
        let settings = try makeSettings()
        _ = try writeReport(in: directory, modified: Date(timeIntervalSinceNow: -30 * 24 * 3600))
        let launched = Date()

        XCTAssertNil(AppDelegate.unseenCrashReport(in: directory, settings: settings, now: launched))
        XCTAssertEqual(settings.crashReportSeenAt, launched)
        XCTAssertNil(AppDelegate.unseenCrashReport(in: directory, settings: settings))
    }

    func testMissingDirectoryOffersNothingAndLogsOneEntry() throws {
        let missing = try makeDirectory().appendingPathComponent("DiagnosticReports", isDirectory: true)
        let settings = try makeSettings()
        settings.crashReportSeenAt = .distantPast
        let before = EventLog.shared.recent

        XCTAssertNil(AppDelegate.unseenCrashReport(in: missing, settings: settings))

        let added = Array(EventLog.shared.recent.dropFirst(before.count))
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added.first?.category, .system)
        XCTAssertTrue(added.first?.message.hasPrefix("can't read crash reports") == true)
        XCTAssertFalse(added.first?.message.contains(missing.path) == true)
    }
}
