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

    static var bundledVersion: String? { bundledDriverURL.flatMap(driverVersion) }
    static var installedVersion: String? { driverVersion(URL(fileURLWithPath: installedPath)) }

    static var updateAvailable: Bool {
        guard let bundledVersion else { return false }
        guard let installedVersion else { return isInstalled }
        return bundledVersion.compare(installedVersion, options: .numeric) == .orderedDescending
    }

    private static func driverVersion(_ url: URL) -> String? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

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

    /// How long coreaudiod takes to exit and come back after `killall`. Until
    /// then the HAL can still list the devices of the old process.
    static let restartSettle: Duration = .seconds(2)

    /// After an install restarts coreaudiod, wait `restartSettle` so the old
    /// Seiren FX can't count as loaded, then check `deviceLoaded` every
    /// `interval` until it returns true (true) or `timeout` has passed (false).
    static func waitForDevice(timeout: Duration = .seconds(10), interval: Duration = .milliseconds(250),
                              deviceLoaded: () -> Bool,
                              sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }) async -> Bool {
        await sleep(restartSettle)
        var waited = restartSettle
        while true {
            if deviceLoaded() { return true }
            if waited >= timeout { return false }
            await sleep(interval)
            waited += interval
        }
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
