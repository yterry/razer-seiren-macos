import AppKit
import ServiceManagement
import XCTest
@testable import seiren_mac

/// Covers the mapping and the menu item only; nothing here calls
/// `SMAppService` register, unregister or status.
@MainActor
final class LaunchAtLoginTests: XCTestCase {
    private typealias State = AppDelegate.LaunchAtLoginState

    func testAPackagedAppTogglesTheLoginItemAndTheCheckMarkFollowsTheStatus() {
        XCTAssertEqual(AppDelegate.launchAtLoginState(status: .enabled, isAppBundle: true),
                       State(title: "Launch at Login", checked: true, action: .unregister))
        for status in [SMAppService.Status.notRegistered, .notFound] {
            XCTAssertEqual(AppDelegate.launchAtLoginState(status: status, isAppBundle: true),
                           State(title: "Launch at Login", checked: false, action: .register), "\(status)")
        }
    }

    func testALoginItemSwitchedOffInSystemSettingsOpensLoginItems() {
        XCTAssertEqual(AppDelegate.launchAtLoginState(status: .requiresApproval, isAppBundle: true),
                       State(title: "Launch at Login (needs approval)", checked: false, action: .openLoginItems))
    }

    func testAnUnbundledBuildShowsTheItemDisabledWhateverTheStatus() {
        for status in [SMAppService.Status.notRegistered, .enabled, .requiresApproval, .notFound] {
            XCTAssertEqual(AppDelegate.launchAtLoginState(status: status, isAppBundle: false),
                           State(title: "Launch at Login (packaged app only)", checked: false, action: nil),
                           "\(status)")
        }
    }

    func testTheMenuItemCarriesTheStateItsTitleAndCheckMarkShow() throws {
        let enabled = AppDelegate.launchAtLoginItem(State(title: "Launch at Login", checked: true, action: .unregister))
        XCTAssertEqual(enabled.title, "Launch at Login")
        XCTAssertEqual(enabled.state, .on)
        XCTAssertTrue(enabled.isEnabled)
        XCTAssertNotNil(enabled.action)
        XCTAssertEqual(try XCTUnwrap(enabled.representedObject as? AppDelegate.LaunchAtLoginAction), .unregister)

        let approval = AppDelegate.launchAtLoginItem(
            State(title: "Launch at Login (needs approval)", checked: false, action: .openLoginItems))
        XCTAssertEqual(approval.state, .off)
        XCTAssertTrue(approval.isEnabled)
        XCTAssertEqual(try XCTUnwrap(approval.representedObject as? AppDelegate.LaunchAtLoginAction),
                       .openLoginItems)

        let unbundled = AppDelegate.launchAtLoginItem(
            State(title: "Launch at Login (packaged app only)", checked: false, action: nil))
        XCTAssertEqual(unbundled.title, "Launch at Login (packaged app only)")
        XCTAssertFalse(unbundled.isEnabled)
        XCTAssertNil(unbundled.action)
    }
}
