import AppKit
import SeirenKit
import XCTest
@testable import seiren_mac

@MainActor
final class FirstLaunchTests: XCTestCase {
    /// A throwaway suite stored in its own temporary directory, never the standard domain.
    private func makeDefaults() throws -> UserDefaults {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeirenMacTests.FirstLaunchTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suiteName = directory.appendingPathComponent("defaults").path
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
            try FileManager.default.removeItem(at: directory)
        }
        return defaults
    }

    /// One launch: returns whether the welcome was shown and whether Auto was turned on.
    private func launch(_ defaults: UserDefaults,
                        answering answer: NSApplication.ModalResponse) -> (asked: Bool, turnedOnAuto: Bool) {
        var asked = false
        var turnedOnAuto = false
        AppDelegate.welcomeOnFirstLaunch(settings: Settings(defaults), ask: {
            asked = true
            return answer
        }, turnOnAuto: { turnedOnAuto = true })
        return (asked, turnedOnAuto)
    }

    func testWelcomeSaysWhereTheAppIsAndOffersAuto() throws {
        let alert = AppDelegate.welcomeAlert()
        XCTAssertTrue(alert.messageText.contains("menu bar"))
        XCTAssertEqual(alert.buttons.map(\.title), ["Turn on Auto", "Not now"])
        XCTAssertEqual(alert.buttons.map(\.keyEquivalent), ["\r", "\u{1b}"])
    }

    func testTurnOnAutoTurnsAutoOnAndTheWelcomeNeverReturns() throws {
        let defaults = try makeDefaults()

        let first = launch(defaults, answering: .alertFirstButtonReturn)
        XCTAssertTrue(first.asked)
        XCTAssertTrue(first.turnedOnAuto)

        let second = launch(defaults, answering: .alertFirstButtonReturn)
        XCTAssertFalse(second.asked)
        XCTAssertFalse(second.turnedOnAuto)
    }

    func testNotNowLeavesTheAppInOffAndTheWelcomeNeverReturns() throws {
        let defaults = try makeDefaults()

        let first = launch(defaults, answering: .alertSecondButtonReturn)
        XCTAssertTrue(first.asked)
        XCTAssertFalse(first.turnedOnAuto)
        XCTAssertEqual(Settings(defaults).mode, .off)

        let second = launch(defaults, answering: .alertFirstButtonReturn)
        XCTAssertFalse(second.asked)
        XCTAssertFalse(second.turnedOnAuto)
    }

    func testAnUpgradeWithASavedModeShowsNoWelcome() throws {
        let defaults = try makeDefaults()
        defaults.set(6, forKey: "schemaVersion")
        defaults.set("always", forKey: "monitorMode")

        let upgraded = launch(defaults, answering: .alertFirstButtonReturn)
        XCTAssertFalse(upgraded.asked)
        XCTAssertFalse(upgraded.turnedOnAuto)
        XCTAssertEqual(Settings(defaults).mode, .always)
    }
}
