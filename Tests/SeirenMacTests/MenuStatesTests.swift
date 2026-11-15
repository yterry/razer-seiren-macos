import AppKit
import SeirenKit
import XCTest
@testable import seiren_mac

/// Submenus that show an empty or error state instead of their usual items.
@MainActor
final class MenuStatesTests: XCTestCase {
    func testAddAppWithNothingToAddShowsOneDisabledLine() throws {
        let menu = AppDelegate.addAppMenu([], atLimit: false, target: nil)
        XCTAssertEqual(menu.items.map(\.title), ["No other apps are open"])
        let item = try XCTUnwrap(menu.items.first)
        XCTAssertFalse(item.isEnabled)
        XCTAssertNil(item.action)
    }

    func testAddAppListsEachChoiceWithItsBundleID() throws {
        let target = NSObject()
        let menu = AppDelegate.addAppMenu([.init(bundleID: "com.example.music", name: "Music", icon: nil)],
                                          atLimit: false, target: target)
        XCTAssertEqual(menu.items.map(\.title), ["Music"])
        let item = try XCTUnwrap(menu.items.first)
        XCTAssertTrue(item.isEnabled)
        XCTAssertEqual(item.action, NSSelectorFromString("addMixerApp:"))
        XCTAssertTrue(item.target === target)
        XCTAssertEqual(item.representedObject as? String, "com.example.music")
    }

    func testAddAppAtTheChannelLimitSaysSoAndListsNothing() throws {
        let menu = AppDelegate.addAppMenu([.init(bundleID: "com.example.music", name: "Music", icon: nil)],
                                          atLimit: true, target: nil)
        XCTAssertEqual(menu.items.map(\.title), ["Up to 6 apps"])
        XCTAssertFalse(try XCTUnwrap(menu.items.first).isEnabled)
    }

    func testALightingErrorOffersTryAgainUnderTheErrorLine() throws {
        let target = NSObject()
        let menu = AppDelegate.lightingMenu(lastError: .noReply, deviceConnected: true, current: nil, target: target)
        let titles = menu.items.map(\.title)
        let error = try XCTUnwrap(titles.firstIndex(of: "Couldn't reach the mic's lighting"))
        XCTAssertFalse(menu.items[error].isEnabled)
        XCTAssertEqual(titles.count, error + 2)
        let retry = menu.items[error + 1]
        XCTAssertEqual(retry.title, "Try Again")
        XCTAssertTrue(retry.isEnabled)
        XCTAssertEqual(retry.action, NSSelectorFromString("retryLighting"))
        XCTAssertTrue(retry.target === target)
        XCTAssertTrue(AppDelegate.instancesRespond(to: NSSelectorFromString("retryLighting")))
    }

    func testLightingWithoutAnErrorOrWithADeniedPermissionOffersNoTryAgain() {
        for error in [nil, LightingError.permissionDenied] {
            let menu = AppDelegate.lightingMenu(lastError: error, deviceConnected: true, current: nil, target: nil)
            XCTAssertFalse(menu.items.contains { $0.title == "Try Again" }, "\(String(describing: error))")
            XCTAssertFalse(menu.items.contains { $0.title.hasPrefix("Couldn't reach") }, "\(String(describing: error))")
        }
    }

    func testUnpluggedLightingWithAStaleTransientErrorShowsOnlyTheConnectLine() {
        assertUnpluggedLightingShowsOnlyTheConnectLine(lastError: .noReply)
    }

    func testUnpluggedLightingWithNoDeviceErrorShowsOnlyTheConnectLine() {
        assertUnpluggedLightingShowsOnlyTheConnectLine(lastError: .noDevice)
    }

    private func assertUnpluggedLightingShowsOnlyTheConnectLine(lastError: LightingError,
                                                                file: StaticString = #filePath,
                                                                line: UInt = #line) {
        let menu = AppDelegate.lightingMenu(lastError: lastError, deviceConnected: false, current: nil,
                                            target: NSObject())
        let titles = menu.items.map(\.title)
        XCTAssertEqual(titles.first, "Applies when the Seiren is connected", file: file, line: line)
        XCTAssertFalse(titles.contains { $0.hasPrefix("Couldn't reach") }, file: file, line: line)
        XCTAssertFalse(titles.contains("Try Again"), file: file, line: line)
    }
}
