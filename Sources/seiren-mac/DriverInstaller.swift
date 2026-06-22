import AppKit
import Foundation

/// Installs the bundled SeirenFX virtual-audio driver into the system HAL
/// plug-in directory using a single native admin prompt (osascript "with
/// administrator privileges"). This works for an *unsigned* app — no paid
/// Developer ID required — and is how a downloaded Seiren.app enables the
/// EQ-reaches-other-apps feature without the user touching Terminal.
@MainActor
enum DriverInstaller {

    static let halDirectory = "/Library/Audio/Plug-Ins/HAL"
    static let installedPath = "\(halDirectory)/SeirenFX.driver"

    /// The SeirenFX.driver shipped inside the app bundle, if present. Absent in a
    /// bare `swift run` dev build (no .app), present in a packaged release.
    static var bundledDriverURL: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("SeirenFX.driver"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static var isBundled: Bool { bundledDriverURL != nil }
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: installedPath) }

    enum Result {
        case ok
        case cancelled
        case failed(String)
    }

    /// Copy the bundled driver into the HAL directory (root-owned) and restart
    /// coreaudiod, all under one admin prompt.
    static func install() -> Result {
        guard let src = bundledDriverURL else {
            return .failed("The bundled SeirenFX.driver wasn't found in the app.")
        }
        // Single-quoted paths so spaces are safe; only the copy chain gates
        // success — killall is best-effort (coreaudiod respawns automatically).
        let shell = """
        mkdir -p '\(halDirectory)' \
        && rm -rf '\(installedPath)' \
        && cp -R '\(src.path)' '\(halDirectory)/' \
        && chown -R root:wheel '\(installedPath)' \
        && chmod -R 755 '\(installedPath)' \
        && (killall coreaudiod 2>/dev/null || true)
        """
        return runPrivileged(shell)
    }

    static func uninstall() -> Result {
        let shell = "rm -rf '\(installedPath)' && (killall coreaudiod 2>/dev/null || true)"
        return runPrivileged(shell)
    }

    /// Run a shell command with admin rights via osascript. Returns `.cancelled`
    /// if the user dismisses the auth dialog.
    private static func runPrivileged(_ command: String) -> Result {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
                             .replacingOccurrences(of: "\"", with: "\\\"")
        let applescript = "do shell script \"\(escaped)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", applescript]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failed(error.localizedDescription)
        }

        if process.terminationStatus == 0 { return .ok }

        let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
        if errText.contains("-128") || errText.localizedCaseInsensitiveContains("cancel") {
            return .cancelled
        }
        return .failed(errText.isEmpty ? "Installation failed (exit \(process.terminationStatus))." : errText)
    }
}
