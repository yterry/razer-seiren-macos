import AppKit
import ServiceManagement

extension AppDelegate {
    enum LaunchAtLoginAction {
        case register, unregister, openLoginItems
    }

    struct LaunchAtLoginState: Equatable {
        var title: String
        var checked: Bool
        /// nil when the item is disabled.
        var action: LaunchAtLoginAction?
    }

    /// What the Launch at Login item shows and does. An unbundled build
    /// (`swift run`) can't register a login item, and `.requiresApproval`
    /// means the user switched it off in System Settings, where it has to be
    /// switched back on.
    static func launchAtLoginState(status: SMAppService.Status, isAppBundle: Bool) -> LaunchAtLoginState {
        guard isAppBundle else {
            return LaunchAtLoginState(title: Strings.launchAtLoginPackagedOnly, checked: false, action: nil)
        }
        switch status {
        case .enabled:
            return LaunchAtLoginState(title: Strings.launchAtLogin, checked: true, action: .unregister)
        case .requiresApproval:
            return LaunchAtLoginState(title: Strings.launchAtLoginNeedsApproval, checked: false,
                                      action: .openLoginItems)
        case .notRegistered, .notFound:
            return LaunchAtLoginState(title: Strings.launchAtLogin, checked: false, action: .register)
        @unknown default:
            return LaunchAtLoginState(title: Strings.launchAtLogin, checked: false, action: .register)
        }
    }

    static func launchAtLoginItem(_ state: LaunchAtLoginState) -> NSMenuItem {
        let item = NSMenuItem(title: state.title,
                              action: state.action == nil ? nil : #selector(AppDelegate.launchAtLoginClicked(_:)),
                              keyEquivalent: "")
        item.state = state.checked ? .on : .off
        item.isEnabled = state.action != nil
        item.representedObject = state.action
        return item
    }

    @objc private func launchAtLoginClicked(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? LaunchAtLoginAction else { return }
        do {
            switch action {
            case .register:
                try SMAppService.mainApp.register()
            case .unregister:
                try SMAppService.mainApp.unregister()
            case .openLoginItems:
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            presentError(action == .unregister ? Strings.launchAtLoginTurnOffFailed(error.localizedDescription)
                                               : Strings.launchAtLoginTurnOnFailed(error.localizedDescription))
        }
        rebuildMenu()
    }
}
