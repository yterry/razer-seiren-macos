import AppKit
import SeirenKit

extension AppDelegate {
    func streamMixerMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Stream Mixer", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.delegate = self
        mixerMenu = submenu
        populateMixerMenu(submenu)
        item.submenu = submenu
        return item
    }

    func populateMixerMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        mixerRows = []
        displayedMixerState = mixerMenuState
        switch mixer.availability {
        case .needsFX, .needsDriverUpdate:
            let updating = mixer.availability == .needsDriverUpdate
            if DriverInstaller.isBundled {
                menu.addItem(driverMenuItem(updating ? .update : .install))
                menu.addItem(disabledItem(updating ? "Adds the Seiren Stream Mix device" : "Adds Seiren FX and Seiren Stream Mix"))
            } else {
                menu.addItem(disabledItem("Rebuild the driver: scripts/build-driver.sh"))
                menu.addItem(disabledItem("then: sudo scripts/install-driver.sh"))
            }
            return
        case .unsupportedOS:
            menu.addItem(disabledItem("Needs macOS 14.2 or later"))
            return
        default: break
        }
        let toggle = NSMenuItem(title: "Mix into Seiren Stream Mix",
                                action: #selector(toggleMixer), keyEquivalent: "")
        toggle.target = self
        toggle.state = mixer.isEnabled ? .on : .off
        menu.addItem(toggle)
        menu.addItem(disabledItem("In OBS, pick “Seiren Stream Mix” as the mic"))
        guard mixer.isEnabled else { return }
        menu.addItem(.separator())
        for channel in mixer.channels {
            let item = NSMenuItem()
            let row = MixerChannelView(channel: channel, icon: mixerIcon(for: channel.source)) { [weak self] updated in
                guard let self else { return }
                self.mixer.setLevel(updated.level, for: updated.source)
                self.mixer.setMuted(updated.muted, for: updated.source)
                self.settings.mixerChannels = self.mixer.channels
            }
            if channel.source == .desktop { row.toolTip = "Every app without its own channel" }
            item.view = row
            mixerRows.append(row)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let appChannels = mixer.channels.filter { if case .app = $0.source { return true }; return false }
        let add = NSMenuItem(title: "Add App", action: nil, keyEquivalent: "")
        let atLimit = appChannels.count >= MixerEngine.maxAppChannels
        add.submenu = Self.addAppMenu(atLimit ? [] : addableApps(excluding: appChannels), atLimit: atLimit,
                                      target: self)
        menu.addItem(add)
        let remove = NSMenuItem(title: "Remove App", action: nil, keyEquivalent: "")
        let removing = NSMenu()
        removing.autoenablesItems = false
        for channel in appChannels {
            guard case .app(let id) = channel.source else { continue }
            let choice = NSMenuItem(title: channel.name, action: #selector(removeMixerApp(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = id
            choice.image = mixerIcon(for: channel.source)
            removing.addItem(choice)
        }
        remove.submenu = removing
        remove.isHidden = appChannels.isEmpty
        menu.addItem(remove)
        menu.addItem(.separator())
        switch mixer.state {
        case .running: menu.addItem(disabledItem("Live · mixing into Seiren Stream Mix"))
        case .failed(let code):
            menu.addItem(disabledItem("Couldn't start the Stream Mixer"))
            menu.addItem(disabledItem(CoreAudioCode.errorDescription(code)))
            let retry = NSMenuItem(title: "Try Again", action: #selector(retryMixer), keyEquivalent: "")
            retry.target = self
            menu.addItem(retry)
        default: menu.addItem(disabledItem("Starts when an app records Seiren Stream Mix"))
        }
        if engine.mode == .off {
            if case .failed = mixer.state { menu.addItem(.separator()) }
            menu.addItem(disabledItem("Voice is silent while monitoring is Off"))
        }
    }

    /// An open app that can get its own Stream Mixer channel.
    struct MixerAppChoice {
        var bundleID: String
        var name: String
        var icon: NSImage?
    }

    /// The open apps that have no channel yet, by name, each listed once.
    private func addableApps(excluding appChannels: [MixerEngine.Channel]) -> [MixerAppChoice] {
        let candidates = NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let id = app.bundleIdentifier, !MixerEngine.isWebAppShim(bundleID: id) else { return false }
            return id != Bundle.main.bundleIdentifier && !appChannels.contains { $0.source == .app(bundleID: id) }
        }.sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
        var seen: Set<String> = []
        return candidates.compactMap { app in
            guard let id = app.bundleIdentifier, seen.insert(id).inserted else { return nil }
            return MixerAppChoice(bundleID: id, name: app.localizedName ?? id, icon: sizedMixerIcon(app.icon))
        }
    }

    /// The "Add App" submenu: one item per app in `choices`, or a disabled
    /// line saying why there is nothing to add.
    static func addAppMenu(_ choices: [MixerAppChoice], atLimit: Bool, target: AnyObject?) -> NSMenu {
        let apps = NSMenu()
        apps.autoenablesItems = false
        if atLimit {
            apps.addItem(disabledItem("Up to 6 apps"))
            return apps
        }
        if choices.isEmpty { apps.addItem(disabledItem("No other apps are open")) }
        for app in choices {
            let choice = NSMenuItem(title: app.name, action: #selector(AppDelegate.addMixerApp(_:)),
                                    keyEquivalent: "")
            choice.target = target
            choice.representedObject = app.bundleID
            choice.image = app.icon
            apps.addItem(choice)
        }
        return apps
    }

    private func sizedMixerIcon(_ image: NSImage?) -> NSImage? {
        let icon = image?.copy() as? NSImage
        icon?.size = NSSize(width: 16, height: 16)
        return icon
    }

    private func mixerIcon(for source: MixerEngine.Source) -> NSImage? {
        switch source {
        case .voice: return NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
        case .desktop: return NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
        case .app(let id):
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.icon
            let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map {
                NSWorkspace.shared.icon(forFile: $0.path)
            }
            return sizedMixerIcon(running ?? installed)
        }
    }

    @objc private func toggleMixer() {
        mixer.setEnabled(!mixer.isEnabled)
        settings.mixerEnabled = mixer.isEnabled
        engine.includeStreamMixInTriggers = mixer.isEnabled
    }

    @objc private func retryMixer() {
        mixer.retryNow()
    }

    @objc private func addMixerApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        mixer.addApp(bundleID: id, name: sender.title)
        settings.mixerChannels = mixer.channels
    }

    @objc private func removeMixerApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        mixer.removeApp(bundleID: id)
        settings.mixerChannels = mixer.channels
    }
}
