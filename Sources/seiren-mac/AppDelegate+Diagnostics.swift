import AppKit
import AVFoundation
import IOKit.hid
import SeirenKit

extension AppDelegate {
    @objc func copyDiagnostics() {
        let report = DiagnosticsReport.render(diagnosticsSnapshot())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    private func diagnosticsSnapshot() -> DiagnosticsSnapshot {
        let needsReinstall = engine.fxNeedsReinstall
        let versions = DiagnosticsSnapshot.Versions(
            app: Self.appVersion,
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: Self.machineArchitecture,
            installedFX: Self.installedFXVersion,
            bundledFX: DriverInstaller.bundledVersion,
            reinstallOffered: needsReinstall,
            updateOffered: DriverInstaller.isBundled && offeredDriverAction == .update)
        let engineState = DiagnosticsSnapshot.Engine(
            mode: engine.mode, state: engine.state, inputPreference: engine.inputPreference,
            activeSource: engine.activeSource, routesThroughFX: engine.isRoutingThroughFX,
            fxRouteFailure: engine.fxRouteFailure, standbyRunning: engine.isStandbyRunning,
            route: engine.routeDiagnostics, recordingBundleIDs: engine.recordingBundleIDs)
        let mixerState = DiagnosticsSnapshot.Mixer(
            enabled: mixer.isEnabled, availability: mixer.availability, state: mixer.state,
            channelCount: mixer.channels.count, diagnostics: mixer.diagnostics)
        let lightingState = DiagnosticsSnapshot.Lighting(
            attachedModel: lighting.attachedModel?.name, deviceConnected: lighting.deviceConnected,
            lastError: lighting.lastError)
        let microphone: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = "authorized"
        case .denied: microphone = "denied"
        case .restricted: microphone = "restricted"
        case .notDetermined: microphone = "not determined"
        @unknown default: microphone = "unknown"
        }
        let inputMonitoring: String
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: inputMonitoring = "granted"
        case kIOHIDAccessTypeDenied: inputMonitoring = "denied"
        default: inputMonitoring = "unknown"
        }
        return DiagnosticsSnapshot(versions: versions, engine: engineState,
                                   devices: AudioDevices.diagnosticsDevices(), mixer: mixerState,
                                   lighting: lightingState, microphoneAccess: microphone,
                                   inputMonitoringAccess: inputMonitoring,
                                   history: EventLog.shared.recent.map(\.description))
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    /// The installed driver's version; nil when it is not installed.
    static var installedFXVersion: String? {
        DriverInstaller.installedVersion ?? (DriverInstaller.isInstalled ? "unknown version" : nil)
    }

    /// The slice that is running, and whether an Intel slice runs under Rosetta.
    private static var machineArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let rosetta = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
        return rosetta ? "x86_64 under Rosetta" : "x86_64"
        #endif
    }

    /// The line that says a newer release is out; it opens the release page.
    static func newReleaseItem(_ release: UpdateChecker.Release, target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: "Version \(release.version) is available",
                              action: #selector(openNewRelease), keyEquivalent: "")
        item.target = target
        item.representedObject = release.url
        return item
    }

    @objc private func openNewRelease(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.open(url) }
    }

    // MARK: - Crash report

    static let diagnosticReportsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    static let bugReportURL = URL(string:
        "https://github.com/yterry/razer-seiren-macos/issues/new?template=bug.yml")!

    /// This app's newest crash report in `directory` written after the stored
    /// `crashReportSeenAt`, or nil. With no stored time (a new install, or the
    /// first launch of a version with this check) it stores `now` and offers
    /// nothing, so reports from before this version ran are never offered.
    /// A missing or unreadable directory logs one entry and returns nil.
    static func unseenCrashReport(in directory: URL, settings: Settings, now: Date = Date()) -> URL? {
        guard let seenAt = settings.crashReportSeenAt else {
            settings.crashReportSeenAt = now
            return nil
        }
        do {
            return try CrashReportFinder.newestReport(in: directory, processName: "seiren-mac",
                                                      after: seenAt)
        } catch {
            // The error text names the folder, whose path has the account name.
            let error = error as NSError
            EventLog.shared.log(category: .system,
                                message: "can't read crash reports: \(error.domain) \(error.code)")
            return nil
        }
    }

    @objc func copyCrashReport() {
        guard let url = crashReport else { return }
        do {
            let report = try String(contentsOf: url, encoding: .utf8)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
            settings.crashReportSeenAt = Date()
        } catch {
            presentError("Couldn't read the crash report: \(error.localizedDescription)")
        }
    }

    @objc func reportCrashOnGitHub() {
        settings.crashReportSeenAt = Date()
        NSWorkspace.shared.open(Self.bugReportURL)
    }

    @objc func dismissCrashReport() {
        settings.crashReportSeenAt = Date()
        crashReport = nil
        rebuildMenu()
    }
}
