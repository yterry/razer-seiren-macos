import XCTest
@testable import seiren_mac

@MainActor
final class DriverInstallerTests: XCTestCase {
    func testWaitForDeviceGivesUpAfterTenSecondsWhenTheDeviceNeverAppears() async {
        var slept = Duration.zero
        let loaded = await DriverInstaller.waitForDevice(deviceLoaded: { false }, sleep: { slept += $0 })
        XCTAssertFalse(loaded)
        XCTAssertEqual(slept, .seconds(10))
    }

    func testWaitForDeviceReturnsAsSoonAsTheDeviceAppears() async {
        var lookups = 0
        var slept = Duration.zero
        let loaded = await DriverInstaller.waitForDevice(deviceLoaded: {
            lookups += 1
            return lookups == 3
        }, sleep: { slept += $0 })
        XCTAssertTrue(loaded)
        XCTAssertEqual(lookups, 3)
        XCTAssertLessThan(slept, .seconds(10))
    }

    func testEveryDriverChangeWarnsAboutTheAudioRestartBeforeThePasswordPrompt() {
        for action in [AppDelegate.DriverAction.install, .update, .reinstall, .uninstall] {
            let alert = AppDelegate.driverConfirmationAlert(action)
            XCTAssertTrue(alert.informativeText.contains("Seiren FX restarts audio on this Mac for about a second."))
            XCTAssertTrue(alert.informativeText.contains("Calls and recordings in other apps will be interrupted."))
            XCTAssertEqual(alert.buttons.map(\.title), [action.verb, "Cancel"])
        }
    }

    func testOnlyAFirstInstallRepeatsTheSetupAdvice() {
        XCTAssertTrue(AppDelegate.driverInstalledAlert(.install).informativeText.contains("Equalizer"))
        for action in [AppDelegate.DriverAction.update, .reinstall] {
            XCTAssertFalse(AppDelegate.driverInstalledAlert(action).informativeText.contains("Equalizer"))
        }
    }
}
