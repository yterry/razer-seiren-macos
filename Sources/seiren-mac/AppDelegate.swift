import AppKit
import AVFoundation
import ServiceManagement
import SeirenKit

/// The menu-bar agent. Owns the status item and a `MonitorEngine`, reflects the
/// engine's state into the menu, and persists the user's monitoring mode.
///
/// Lifetime: the app delegate is created in `main.swift` and lives for the whole
/// process, so the strong reference from `AppDelegate` to `MonitorEngine`, plus
/// the engine's `weak` delegate back to us, is correct and cycle-free.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, MonitorEngineDelegate,
                         LightingControllerDelegate, MixerEngineDelegate, NSMenuDelegate {

    // MARK: - State

    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private var statusMenuIsOpen = false
    var driverChangeInProgress = false
    /// `SEIREN_DEVICE_MATCH` lets a developer point the app at another input
    /// device (e.g. an input-only USB codec standing in for a jack-less Seiren)
    /// to exercise the menu without the hardware. Not a user setting.
    let engine = MonitorEngine(
        deviceNameMatch: ProcessInfo.processInfo.environment["SEIREN_DEVICE_MATCH"] ?? "seiren",
        microphoneAccess: {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .undetermined
            @unknown default: return .undetermined
            }
        })
    let mixer = MixerEngine()
    let lighting = LightingController()
    let settings = Settings()
    private lazy var updateChecker = UpdateChecker(settings: settings, runningVersion: Self.appVersion)
    var levelSlider: NSSlider?
    var mixerMenu: NSMenu?
    var mixerRows: [MixerChannelView] = []
    var displayedMixerState: MixerMenuState?
    // Who is at the Mac, for Auto's standby (see applicationDidFinishLaunching).
    private var screensAsleep = false
    private var systemAsleep = false
    private var sessionInactive = false
    /// The report macOS wrote for a crash the user has not dismissed yet.
    var crashReport: URL?

    struct MixerMenuState: Equatable {
        var enabled: Bool
        var availability: MixerEngine.State
        var state: MixerEngine.State
        var sources: [MixerEngine.Source]
        var voiceOff: Bool
    }

    var mixerMenuState: MixerMenuState {
        MixerMenuState(enabled: mixer.isEnabled, availability: mixer.availability,
                       state: mixer.state, sources: mixer.channels.map(\.source), voiceOff: engine.mode == .off)
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        crashReport = Self.unseenCrashReport(in: Self.diagnosticReportsDirectory, settings: settings)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusMenu.delegate = self
        statusItem.menu = statusMenu
        configureStatusButtonImage()

        engine.delegate = self
        mixer.setChannels(settings.mixerChannels)
        mixer.delegate = self
        mixer.setEnabled(settings.mixerEnabled)
        engine.includeStreamMixInTriggers = mixer.isEnabled

        // Restore persisted level + EQ + noise suppression before auto-resume.
        if let lvl = settings.level { engine.level = lvl }
        engine.setEQPreset(settings.eqPreset)
        engine.setEQEnabled(settings.eqEnabled)
        engine.setNoiseSuppression(settings.noiseSuppression)
        engine.setInputPreference(settings.inputPreference)

        // Lighting: watch for the device; only touch its lights if the user has
        // configured lighting before (state is volatile across replugs).
        lighting.delegate = self
        lighting.start()
        if let state = settings.lightingState { lighting.apply(state) }

        // Sleep wipes the ring: USB power drops and the firmware falls back to
        // its default spectrum effect, usually WITHOUT re-enumerating on wake -
        // so the hotplug callback never fires and the user's choice stays lost.
        // Re-assert it on every wake instead.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        // Auto's standby keeps the Seiren's headphone side running, and running
        // output holds an idle-sleep assertion, so it only runs while someone
        // is at the Mac: displays awake, system awake, this user's session active.
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.willSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(standbyConditionChanged(_:)), name: name, object: nil)
        }
        updateStandbyAllowed()

        rebuildMenu()

        updateChecker.onChange = { [weak self] in self?.rebuildMenu() }
        updateChecker.start()

        // Restore the saved mode (migrating the pre-mode Bool if present). If
        // monitoring should be on, request mic access first so a previously
        // granted user keeps working and a fresh user gets the prompt once.
        let restored = restoredMode()
        if restored == .off {
            engine.setMode(.off)
        } else {
            Self.requestMicrophoneAccessThen { [weak self] in self?.engine.setMode(restored) }
        }

        // A new install starts in Off with a dimmed icon and no window, so say
        // where the app is and offer the recommended mode, once.
        Self.welcomeOnFirstLaunch(settings: settings, ask: {
            NSApp.activate(ignoringOtherApps: true)
            return Self.welcomeAlert().runModal()
        }, turnOnAuto: { applyMode(.auto) })
    }

    func applicationWillTerminate(_ notification: Notification) {
        mixer.shutdown()
        engine.shutdown()
    }

    private func restoredMode() -> MonitorEngine.Mode {
        // Settings.migrate() already upgraded the pre-mode Bool to a mode string.
        settings.mode
    }

    // MARK: - MonitorEngineDelegate

    nonisolated func monitorEngineDidChange(_ engine: MonitorEngine) {
        Task { @MainActor in
            if case .device(let uid) = engine.inputPreference,
               let input = engine.availableInputs.first(where: { $0.uid == uid }) {
                self.settings.inputSourceName = input.name
            }
            self.rebuildMenu()
            self.configureStatusButtonImage()
        }
    }

    nonisolated func mixerEngineDidChange(_ mixer: MixerEngine) {
        Task { @MainActor in
            self.engine.includeStreamMixInTriggers = mixer.isEnabled
            if self.displayedMixerState == self.mixerMenuState {
                for row in self.mixerRows {
                    if let channel = mixer.channels.first(where: { $0.source == row.channel.source }) {
                        row.update(channel)
                    }
                }
            } else if let menu = self.mixerMenu {
                self.populateMixerMenu(menu)
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === mixerMenu { populateMixerMenu(menu) }
        if menu === statusMenu {
            // System Settings can change authorization while the app stays open.
            engine.recheckMicrophoneAccess()
            populateStatusMenu()
            configureStatusButtonImage()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === statusMenu { statusMenuIsOpen = true }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === statusMenu { statusMenuIsOpen = false }
    }

    // MARK: - LightingControllerDelegate

    nonisolated func lightingControllerDidChange(_ controller: LightingController) {
        Task { @MainActor in self.rebuildMenu() }
    }

    // MARK: - Status item icon

    /// A mic glyph: bright with a waveform while actively monitoring, plain mic
    /// while armed/idle, crossed out when the user has to act, dimmed when off.
    /// Template-rendered for light/dark bars; the status line is spoken.
    func configureStatusButtonImage() {
        guard let button = statusItem.button else { return }
        let status = statusLine()
        button.image = Self.statusButtonImage(for: engine.state, fxRouteFailed: engine.fxRouteFailure != nil,
                                              status: status)
        button.appearsDisabled = (engine.mode == .off)
        button.toolTip = status
    }

    /// The status item's glyph for `state`, described by the status line so
    /// VoiceOver speaks the same text the menu and tooltip show.
    static func statusButtonImage(for state: MonitorEngine.State, fxRouteFailed: Bool, status: String) -> NSImage? {
        let image = NSImage(systemSymbolName: statusSymbolName(for: state, fxRouteFailed: fxRouteFailed),
                            accessibilityDescription: status)
        image?.isTemplate = true
        return image
    }

    /// `fxRouteFailed` is whether Seiren FX failed to start and direct
    /// monitoring runs in its place, which needs the user's attention as well.
    static func statusSymbolName(for state: MonitorEngine.State, fxRouteFailed: Bool) -> String {
        if fxRouteFailed { return "mic.badge.xmark" }
        switch state {
        case .permissionDenied, .needsFX, .failed: return "mic.badge.xmark"
        case .running: return "waveform.and.mic"
        case .stopped, .waiting, .noDevice: return "mic"
        }
    }

    // MARK: - Menu construction

    /// The menu on screen keeps its items; `menuNeedsUpdate` populates it
    /// again before the next display.
    func rebuildMenu() {
        guard !statusMenuIsOpen else { return }
        populateStatusMenu()
    }

    private func populateStatusMenu() {
        let menu = statusMenu
        menu.removeAllItems()

        // 0. The app crashed last time: offer the report macOS wrote.
        if crashReport != nil {
            menu.addItem(disabledItem("Seiren quit unexpectedly last time"))
            for (title, action) in [("Copy Crash Report", #selector(copyCrashReport)),
                                    ("Report on GitHub…", #selector(reportCrashOnGitHub)),
                                    ("Dismiss", #selector(dismissCrashReport))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        // 1. Device / state line (disabled, informational).
        menu.addItem(disabledItem(statusLine()))
        if engine.fxRouteFailure != nil {
            menu.addItem(disabledItem("Seiren FX couldn't start - apps using it hear silence"))
        }
        if engine.state == .waiting, engine.activeSource?.isSeiren == false {
            menu.addItem(disabledItem("Starts when an app records from Seiren FX"))
        }

        // 2. Helpers for the states only the user can fix.
        if engine.state == .permissionDenied {
            menu.addItem(disabledItem("Microphone access is required"))
            let open = NSMenuItem(title: "Open Microphone Settings…",
                                  action: #selector(openMicrophoneSettings),
                                  keyEquivalent: "")
            open.target = self
            menu.addItem(open)
        }
        if engine.state == .needsFX { addNeedsFXItems(to: menu) } else { addDriverUpdateItems(to: menu) }
        let failureCode: OSStatus?
        if case .failed(let code) = engine.state { failureCode = code } else { failureCode = engine.fxRouteFailure }
        if let code = failureCode {
            menu.addItem(disabledItem(Self.coreAudioErrorLine(code)))
            let retry = NSMenuItem(title: "Try Again", action: #selector(retryAudio), keyEquivalent: "")
            retry.target = self
            menu.addItem(retry)
        }

        menu.addItem(.separator())

        // 3. Mode — three mutually-exclusive choices (radio-style checkmarks).
        menu.addItem(modeItem("Off", .off))
        menu.addItem(modeItem("On — always", .always))
        let auto = modeItem("Auto — only while an app uses the mic", .auto)
        menu.addItem(auto)

        menu.addItem(.separator())

        // 4. Volume — an embedded NSSlider. Enabled whenever monitoring isn't off.
        //    A jack-less mic (V3 Mini) has no monitor to set a level for, so the
        //    slider is left out rather than shown dead.
        if engine.deviceHasHeadphoneOutput {
            menu.addItem(volumeItem(enabled: engine.mode != .off))
            menu.addItem(.separator())
        }

        // 5. Voice — parametric EQ (creator path; needs SeirenFX).
        menu.addItem(inputMenuItem())
        menu.addItem(voiceMenuItem())
        menu.addItem(streamMixerMenuItem())

        menu.addItem(.separator())

        // 5b. Lighting — the Chroma ring, over the vendor HID channel. Hidden
        //     when the attached mic is a known model without one (V3 Mini):
        //     controls that can never apply are worse than none.
        if lightingApplies {
            menu.addItem(lightingMenuItem())
            menu.addItem(.separator())
        }

        // 6. Launch at login (SMAppService, macOS 13+). The status is read on
        //    every menu open, so a change made in System Settings shows up.
        let login = Self.launchAtLoginItem(Self.launchAtLoginState(
            status: SMAppService.mainApp.status, isAppBundle: Bundle.main.bundleURL.pathExtension == "app"))
        login.target = self
        menu.addItem(login)

        menu.addItem(.separator())

        // 7. Versions, and a bug report that needs no Swift toolchain.
        menu.addItem(disabledItem(DiagnosticsReport.versionLine(app: Self.appVersion,
                                                               installedFX: Self.installedFXVersion)))
        if let release = updateChecker.available {
            menu.addItem(Self.newReleaseItem(release, target: self))
        }
        let copy = NSMenuItem(title: "Copy Diagnostics", action: #selector(copyDiagnostics), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)

        menu.addItem(.separator())

        // 8. Quit.
        let quit = NSMenuItem(title: "Quit Seiren",
                              action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func modeItem(_ title: String, _ mode: MonitorEngine.Mode) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(selectMode(_:)), keyEquivalent: "")
        item.target = self
        item.state = (engine.mode == mode) ? .on : .off
        item.representedObject = mode.rawValue
        return item
    }

    /// Human-readable device + state line for the top of the menu / tooltip.
    private func statusLine() -> String {
        let device = engine.activeSource?.name ?? "Seiren"
        if engine.activeSource?.isSeiren == false {
            switch engine.state {
            case .running:
                return engine.inputPreference == .automatic
                    ? "No Seiren · Seiren FX is using \(device)"
                    : "Processing: \(device) → Seiren FX"
            case .waiting:
                return engine.inputPreference == .automatic
                    ? "No Seiren · Seiren FX will use \(device)"
                    : "Standby: \(device) → Seiren FX"
            default: break
            }
        }
        switch engine.state {
        case .running:
            // A jack-less mic isn't being monitored - its voice is being
            // processed into Seiren FX for other apps. Say that instead.
            return engine.deviceHasHeadphoneOutput
                ? "Monitoring: \(device)"
                : "Processing: \(device) → Seiren FX"
        case .waiting:
            return "Auto: waiting for an app to use the mic"
        case .noDevice:
            return engine.fxAvailable && engine.otherInputsSupported ? "No microphone detected" : "No Seiren detected"
        case .needsFX:
            return "\(device) needs Seiren FX"
        case .permissionDenied:
            return "Microphone access denied"
        case .failed:
            return "Couldn't start audio"
        case .stopped:
            return engine.activeSource.map { "Ready: \($0.name)" } ?? "Monitoring off"
        }
    }

    /// A menu item hosting a slider under a small visible caption. The slider
    /// carries the full name as its accessibility label and tooltip, so the
    /// caption is hidden from accessibility to keep VoiceOver from reading it twice.
    /// Both are set on the cells: accessibility ignores a single-cell control and
    /// exposes its cell, and a setting made on the control never reaches the cell.
    static func sliderItem(caption: String, label: String, slider: PercentSlider) -> NSMenuItem {
        let item = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
        container.autoresizingMask = [.width]   // the menu sizes it to its own width

        let captionField = NSTextField(labelWithString: caption)
        captionField.frame = NSRect(x: 14, y: 22, width: 100, height: 14)
        captionField.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        captionField.textColor = .secondaryLabelColor
        captionField.cell?.setAccessibilityElement(false)
        container.addSubview(captionField)

        slider.frame = NSRect(x: 14, y: 4, width: 212, height: 19)
        slider.autoresizingMask = [.width]
        slider.toolTip = label
        slider.cell?.setAccessibilityLabel(label)
        container.addSubview(slider)

        item.view = container
        return item
    }

    static func coreAudioErrorLine(_ code: OSStatus) -> String {
        "Core Audio error \(code)"
    }

    func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = MonitorEngine.Mode(rawValue: raw) else { return }
        applyMode(mode)
    }

    private func applyMode(_ mode: MonitorEngine.Mode) {
        settings.mode = mode
        if mode == .off {
            engine.setMode(.off)
            rebuildMenu()
        } else {
            // Both always/auto read the mic → ensure permission, then apply.
            Self.requestMicrophoneAccessThen { [weak self] in
                guard let self else { return }
                self.engine.setMode(mode)
                self.rebuildMenu()
            }
        }
    }

    @objc private func systemDidWake() {
        EventLog.shared.log(category: .system, message: "system woke")
        systemAsleep = false
        updateStandbyAllowed()
        lighting.reassert()
    }

    @objc private func standbyConditionChanged(_ note: Notification) {
        let event: EventLog.Message
        switch note.name {
        case NSWorkspace.screensDidSleepNotification: screensAsleep = true; event = "screens slept"
        case NSWorkspace.screensDidWakeNotification: screensAsleep = false; event = "screens woke"
        case NSWorkspace.willSleepNotification: systemAsleep = true; event = "system will sleep"
        case NSWorkspace.sessionDidResignActiveNotification: sessionInactive = true; event = "session resigned active"
        case NSWorkspace.sessionDidBecomeActiveNotification: sessionInactive = false; event = "session became active"
        default: return
        }
        EventLog.shared.log(category: .system, message: event)
        updateStandbyAllowed()
    }

    private func updateStandbyAllowed() {
        guard settings.autoStandbyEnabled else {
            engine.setStandbyAllowed(false, reason: "disabled by preference")
            return
        }
        engine.setStandbyAllowed(!screensAsleep && !systemAsleep && !sessionInactive)
    }

    @objc private func retryAudio() {
        engine.retryNow()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Seiren"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
