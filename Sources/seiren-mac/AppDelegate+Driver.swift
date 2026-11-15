import AppKit
import SeirenKit

extension AppDelegate {
    /// Top-level helper for `.needsFX`: the attached mic has no headphone jack
    /// and Seiren FX isn't installed, so nothing can run yet. Says why in one
    /// line and puts the install action where the user is already looking.
    func addNeedsFXItems(to menu: NSMenu) {
        menu.addItem(disabledItem("This mic has no headphone jack - it works through Seiren FX"))
        if DriverInstaller.isBundled {
            menu.addItem(driverMenuItem(offeredDriverAction ?? .install))
        } else {
            menu.addItem(disabledItem("Install Seiren FX first (scripts/install-driver.sh)"))
        }
    }

    /// Top-level notice when the bundled Seiren FX should replace the installed
    /// one, so a user who never opens Voice still learns about it.
    func addDriverUpdateItems(to menu: NSMenu) {
        guard DriverInstaller.isBundled, let action = offeredDriverAction, action != .install else { return }
        menu.addItem(disabledItem(action == .reinstall
            ? "Seiren FX needs a one-time reinstall" : "A newer Seiren FX comes with this app"))
        menu.addItem(driverMenuItem(action))
    }

    /// The driver change the menu offers for the current state, if any.
    var offeredDriverAction: DriverAction? {
        Self.offeredDriverAction(fxLoaded: engine.fxAvailable, needsReinstall: engine.fxNeedsReinstall,
                                 updateAvailable: DriverInstaller.updateAvailable)
    }

    /// A Seiren FX that macOS has not loaded is offered as a first install,
    /// whatever is on disk: the user has never had it working.
    static func offeredDriverAction(fxLoaded: Bool, needsReinstall: Bool, updateAvailable: Bool) -> DriverAction? {
        if needsReinstall { return .reinstall }
        if !fxLoaded { return .install }
        return updateAvailable ? .update : nil
    }

    /// A menu item that runs `action`; the confirmation and result dialogs use
    /// the same verb as the item's title.
    static func driverMenuItem(_ action: DriverAction) -> NSMenuItem {
        let item = NSMenuItem(title: "\(action.verb) Seiren FX…",
                              action: #selector(AppDelegate.changeDriver(_:)), keyEquivalent: "")
        item.representedObject = action
        return item
    }

    func driverMenuItem(_ action: DriverAction) -> NSMenuItem {
        let item = Self.driverMenuItem(action)
        item.target = self
        return item
    }

    enum DriverAction {
        case install, update, reinstall, uninstall

        var verb: String {
            switch self {
            case .install: "Install"
            case .update: "Update"
            case .reinstall: "Reinstall"
            case .uninstall: "Uninstall"
            }
        }
    }

    /// Asked before the password prompt: every driver change restarts coreaudiod.
    static func driverConfirmationAlert(_ action: DriverAction) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "\(action.verb) Seiren FX?"
        alert.informativeText = "\(action == .uninstall ? "Uninstalling" : "Installing") Seiren FX " +
            "restarts audio on this Mac for about a second. " +
            "Calls and recordings in other apps will be interrupted."
        alert.addButton(withTitle: action.verb)
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    /// Shown once the installed Seiren FX device has loaded. Only a first
    /// install gets the setup advice.
    static func driverInstalledAlert(_ action: DriverAction) -> NSAlert {
        let alert = NSAlert()
        if action == .install {
            alert.messageText = "Seiren FX installed"
            alert.informativeText = "Audio was restarted. Turn on the Equalizer under " +
                "Voice, then choose “Seiren FX” as the microphone in OBS / Zoom / " +
                "Discord to send them your processed voice."
        } else {
            alert.messageText = action == .update ? "Seiren FX updated" : "Seiren FX reinstalled"
            alert.informativeText = "Audio was restarted. Your Voice settings and the apps " +
                "that use Seiren FX keep working as before."
        }
        return alert
    }

    static func driverNotLoadedAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Seiren FX was copied but macOS did not load it"
        alert.informativeText = "The driver is at:\n\(DriverInstaller.installedPath)\n\n" +
            "Restart the Mac to load it."
        alert.alertStyle = .warning
        return alert
    }

    /// Runs the driver change named by the clicked item. Ignored while an
    /// earlier change is still waiting for coreaudiod, so a second click can't
    /// save the paused mode as the one to restore.
    @objc private func changeDriver(_ sender: NSMenuItem) {
        guard !driverChangeInProgress, let action = sender.representedObject as? DriverAction,
              Self.runAlert(Self.driverConfirmationAlert(action)) == .alertFirstButtonReturn else { return }
        if action == .uninstall { uninstallDriver() } else { installDriver(action) }
    }

    private func installDriver(_ action: DriverAction) {
        switch DriverInstaller.install() {
        case .cancelled:
            return
        case .failed(let why):
            presentError("Couldn't install Seiren FX:\n\(why)\n\n" +
                         "You can also install it manually with scripts/install-driver.sh.")
            return
        case .ok:
            // coreaudiod just restarted: force a clean re-acquire so the engine
            // drops the now-dead IOProc and picks up the new Seiren FX device
            // once macOS has loaded it.
            let resume = pauseAudioForRestart()
            Task { @MainActor [weak self] in
                guard let self else { return }
                let loaded = await DriverInstaller.waitForDevice { [engine] in
                    engine.fxAvailable && !engine.fxNeedsReinstall
                }
                resume()
                Self.runAlert(loaded ? Self.driverInstalledAlert(action) : Self.driverNotLoadedAlert())
            }
        }
    }

    private func uninstallDriver() {
        switch DriverInstaller.uninstall() {
        case .cancelled:
            return
        case .failed(let why):
            presentError("Couldn't uninstall Seiren FX:\n\(why)")
        case .ok:
            // Nothing to wait for once the device is gone; give coreaudiod
            // time to come back before re-acquiring.
            let resume = pauseAudioForRestart()
            Task { @MainActor in
                try? await Task.sleep(for: DriverInstaller.restartSettle)
                resume()
            }
        }
    }

    /// Stops the engine and mixer while coreaudiod restarts; the returned
    /// closure restores the mode and mixer the user had.
    private func pauseAudioForRestart() -> @MainActor () -> Void {
        let mode = engine.mode
        let mixing = mixer.isEnabled
        driverChangeInProgress = true
        engine.setMode(.off)
        mixer.setEnabled(false)
        rebuildMenu()
        return { [weak self] in
            guard let self else { return }
            self.driverChangeInProgress = false
            self.engine.setMode(mode)
            self.mixer.setEnabled(mixing)
            self.engine.includeStreamMixInTriggers = self.mixer.isEnabled
            self.rebuildMenu()
        }
    }
}
