import AppKit
import AVFoundation
import SeirenKit

extension AppDelegate {
    // MARK: - First launch

    /// The one dialog a new install shows. Escape answers "Not now".
    static func welcomeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Seiren runs in the menu bar"
        alert.informativeText = "Seiren has no window and no Dock icon. Click the microphone " +
            "icon in the menu bar to change its settings.\n\n" +
            "Auto is the recommended mode. It runs headphone monitoring and voice processing " +
            "only while another app is using the microphone, such as during a call. " +
            "macOS asks for microphone access the first time a mode is turned on."
        alert.addButton(withTitle: "Turn on Auto")
        alert.addButton(withTitle: "Not now").keyEquivalent = "\u{1b}"
        return alert
    }

    /// Asks on a new install's first launch and records that it did, so no
    /// later launch asks again. Only the first button turns Auto on.
    static func welcomeOnFirstLaunch(settings: Settings, ask: () -> NSApplication.ModalResponse,
                                     turnOnAuto: () -> Void) {
        guard !settings.firstRunDone else { return }
        let answer = ask()
        settings.firstRunDone = true
        if answer == .alertFirstButtonReturn { turnOnAuto() }
    }

    // MARK: - Microphone permission

    /// Ensure the prompt has been shown, then apply the chosen mode.
    /// On denial we still call through so the engine can
    /// surface `.permissionDenied` with the Settings shortcut.
    static func requestMicrophoneAccessThen(
        _ onResolved: @escaping @MainActor () -> Void,
        authorizationStatus: () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) },
        requestAccess: (@escaping @Sendable (Bool) -> Void) -> Void = {
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: $0)
        }
    ) {
        switch authorizationStatus() {
        case .authorized:
            onResolved()
        case .notDetermined:
            requestAccess { _ in
                Task { @MainActor in onResolved() }
            }
        case .denied, .restricted:
            onResolved()
        @unknown default:
            onResolved()
        }
    }

    @objc func openMicrophoneSettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
