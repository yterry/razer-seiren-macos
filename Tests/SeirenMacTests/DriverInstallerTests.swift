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

    func testWaitForDeviceIgnoresTheOldDeviceListedWhileCoreaudiodRestarts() async {
        var slept = Duration.zero
        let loaded = await DriverInstaller.waitForDevice(deviceLoaded: { slept < DriverInstaller.restartSettle },
                                                         sleep: { slept += $0 })
        XCTAssertFalse(loaded)
        XCTAssertEqual(slept, .seconds(10))
    }

    func testADriverMacOSNeverLoadedIsOfferedAsAFirstInstall() throws {
        for updateAvailable in [false, true] {
            XCTAssertEqual(AppDelegate.offeredDriverAction(fxLoaded: false, needsReinstall: false,
                                                           updateAvailable: updateAvailable), .install)
        }
        let item = AppDelegate.driverMenuItem(.install)
        XCTAssertEqual(item.title, "Install Seiren FX…")
        let action = try XCTUnwrap(item.representedObject as? AppDelegate.DriverAction)
        let confirmation = AppDelegate.driverConfirmationAlert(action)
        XCTAssertEqual(confirmation.messageText, "Install Seiren FX?")
        XCTAssertEqual(confirmation.buttons.map(\.title), ["Install", "Cancel"])
        let success = AppDelegate.driverInstalledAlert(action)
        XCTAssertEqual(success.messageText, "Seiren FX installed")
        XCTAssertTrue(success.informativeText.contains("Equalizer"))
    }

    func testALoadedDriverIsOfferedAnUpdateOrReinstallOnlyWhenNeeded() {
        XCTAssertEqual(AppDelegate.offeredDriverAction(fxLoaded: true, needsReinstall: false, updateAvailable: true),
                       .update)
        XCTAssertEqual(AppDelegate.offeredDriverAction(fxLoaded: true, needsReinstall: true, updateAvailable: false),
                       .reinstall)
        XCTAssertNil(AppDelegate.offeredDriverAction(fxLoaded: true, needsReinstall: false, updateAvailable: false))
    }

    func testEveryDriverMenuItemCarriesTheActionItsTitleNames() {
        for action in [AppDelegate.DriverAction.install, .update, .reinstall, .uninstall] {
            let item = AppDelegate.driverMenuItem(action)
            XCTAssertEqual(item.title, "\(action.verb) Seiren FX…")
            XCTAssertEqual(item.representedObject as? AppDelegate.DriverAction, action)
            XCTAssertEqual(AppDelegate.driverConfirmationAlert(action).buttons.first?.title, action.verb)
        }
    }

    func testEveryDriverChangeWarnsAboutTheAudioRestartBeforeThePasswordPrompt() {
        for action in [AppDelegate.DriverAction.install, .update, .reinstall, .uninstall] {
            let alert = AppDelegate.driverConfirmationAlert(action)
            XCTAssertTrue(alert.informativeText.contains("Seiren FX restarts audio on this Mac for about a second."))
            XCTAssertTrue(alert.informativeText.contains("Calls and recordings in other apps will be interrupted."))
            XCTAssertEqual(alert.buttons.map(\.title), [action.verb, "Cancel"])
        }
    }

    func testTheNotLoadedDialogPutsTheDriverPathOnItsOwnLine() {
        let alert = AppDelegate.driverNotLoadedAlert()
        XCTAssertEqual(alert.messageText, "Seiren FX was copied but macOS did not load it")
        XCTAssertEqual(alert.informativeText.components(separatedBy: "\n"),
                       ["The driver is at:", "/Library/Audio/Plug-Ins/HAL/SeirenFX.driver", "",
                        "Restart the Mac to load it."])
    }

    func testAnAlertRunsOnlyAfterTheAppIsActivated() {
        let alert = AppDelegate.driverNotLoadedAlert()
        var steps: [String] = []
        let response = AppDelegate.runAlert(alert, activate: { steps.append("activate") }, run: { ran in
            XCTAssertTrue(ran === alert)
            steps.append("run")
            return .alertSecondButtonReturn
        })
        XCTAssertEqual(steps, ["activate", "run"])
        XCTAssertEqual(response, .alertSecondButtonReturn)
    }

    func testOnlyAFirstInstallRepeatsTheSetupAdvice() {
        XCTAssertTrue(AppDelegate.driverInstalledAlert(.install).informativeText.contains("Equalizer"))
        for action in [AppDelegate.DriverAction.update, .reinstall] {
            XCTAssertFalse(AppDelegate.driverInstalledAlert(action).informativeText.contains("Equalizer"))
        }
    }
}
