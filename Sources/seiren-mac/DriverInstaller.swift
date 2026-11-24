import Foundation
import SeirenKit

/// Installs the bundled SeirenFX virtual-audio driver into the system HAL
/// plug-in directory using a single native admin prompt (osascript "with
/// administrator privileges"). This works for an ad-hoc signed app, with no paid
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
            return .failed(Strings.driverNotBundled)
        }
        return result {
            try DriverInstallation.install(source: src, destinationDirectory: URL(fileURLWithPath: halDirectory),
                                           privileged: true, signingIdentity: .runningApp())
        }
    }

    static func uninstall() -> Result {
        result {
            try DriverInstallation.uninstall(at: URL(fileURLWithPath: installedPath), privileged: true)
        }
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

    private static func result(_ operation: () throws -> Void) -> Result {
        do {
            try operation()
            return .ok
        } catch DriverInstallation.Failure.cancelled {
            return .cancelled
        } catch DriverInstallation.Failure.invalidAppSignature {
            return .failed(Strings.driverInvalidAppSignature)
        } catch DriverInstallation.Failure.invalidDriverSignature {
            return .failed(Strings.driverInvalidSignature)
        } catch DriverInstallation.Failure.scriptFailed(let status, let message) {
            return .failed(message.isEmpty ? Strings.driverExitStatus(status) : message)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
