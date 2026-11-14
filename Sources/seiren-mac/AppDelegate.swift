import AppKit
import AVFoundation
import IOKit.hid
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
    /// `SEIREN_DEVICE_MATCH` lets a developer point the app at another input
    /// device (e.g. an input-only USB codec standing in for a jack-less Seiren)
    /// to exercise the menu without the hardware. Not a user setting.
    private let engine = MonitorEngine(
        deviceNameMatch: ProcessInfo.processInfo.environment["SEIREN_DEVICE_MATCH"] ?? "seiren",
        microphoneAccess: {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .undetermined
            @unknown default: return .undetermined
            }
        })
    private let mixer = MixerEngine()
    private let lighting = LightingController()
    private let settings = Settings()
    private var levelSlider: NSSlider?
    private var mixerMenu: NSMenu?
    private var mixerRows: [MixerChannelView] = []
    private var displayedMixerState: MixerMenuState?
    // Who is at the Mac, for Auto's standby (see applicationDidFinishLaunching).
    private var screensAsleep = false
    private var systemAsleep = false
    private var sessionInactive = false

    private struct MixerMenuState: Equatable {
        var enabled: Bool
        var availability: MixerEngine.State
        var state: MixerEngine.State
        var sources: [MixerEngine.Source]
        var voiceOff: Bool
    }

    private var mixerMenuState: MixerMenuState {
        MixerMenuState(enabled: mixer.isEnabled, availability: mixer.availability,
                       state: mixer.state, sources: mixer.channels.map(\.source), voiceOff: engine.mode == .off)
    }

    /// Static color choices for the Lighting menu (name, hex).
    ///
    /// These are LED colors, not screen colors: the ring drives raw RGB
    /// emitters with no color management, so Razer's *brand* green (#44D62C,
    /// an sRGB value for displays) renders washed-out and dim there. The
    /// iconic Razer glow on the hardware itself is pure green - the same
    /// 00FF00 Synapse and openrazer use.
    private static let lightingPalette: [(String, String)] = [
        ("Razer Green", "00FF00"), ("White", "FFFFFF"), ("Red", "FF0000"),
        ("Orange", "FF6A00"), ("Yellow", "FFD400"), ("Cyan", "00FFFF"),
        ("Blue", "0066FF"), ("Purple", "8A2BE2"), ("Pink", "FF1493"),
    ]

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        rebuildMenu()

        // Restore the saved mode (migrating the pre-mode Bool if present). If
        // monitoring should be on, request mic access first so a previously
        // granted user keeps working and a fresh user gets the prompt once.
        let restored = restoredMode()
        if restored == .off {
            engine.setMode(.off)
        } else {
            Self.requestMicrophoneAccessThen { [weak self] in self?.engine.setMode(restored) }
        }
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
    private func configureStatusButtonImage() {
        guard let button = statusItem.button else { return }
        let status = statusLine()
        button.image = Self.statusButtonImage(for: engine.state, status: status)
        button.appearsDisabled = (engine.mode == .off)
        button.toolTip = status
    }

    /// The status item's glyph for `state`, described by the status line so
    /// VoiceOver speaks the same text the menu and tooltip show.
    static func statusButtonImage(for state: MonitorEngine.State, status: String) -> NSImage? {
        let image = NSImage(systemSymbolName: statusSymbolName(for: state), accessibilityDescription: status)
        image?.isTemplate = true
        return image
    }

    static func statusSymbolName(for state: MonitorEngine.State) -> String {
        switch state {
        case .permissionDenied, .needsFX, .failed: return "mic.badge.xmark"
        case .running: return "waveform.and.mic"
        case .stopped, .waiting, .noDevice: return "mic"
        }
    }

    // MARK: - Menu construction

    /// The menu on screen keeps its items; `menuNeedsUpdate` populates it
    /// again before the next display.
    private func rebuildMenu() {
        guard !statusMenuIsOpen else { return }
        populateStatusMenu()
    }

    private func populateStatusMenu() {
        let menu = statusMenu
        menu.removeAllItems()

        // 1. Device / state line (disabled, informational).
        menu.addItem(disabledItem(statusLine()))
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
        if engine.state == .needsFX { addNeedsFXItems(to: menu) }
        if case .failed(let code) = engine.state {
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

        // 6. Launch at login (SMAppService, macOS 13+).
        let login = NSMenuItem(title: "Launch at Login",
                               action: #selector(toggleLaunchAtLogin),
                               keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        // 7. Versions, and a bug report that needs no Swift toolchain.
        menu.addItem(disabledItem(DiagnosticsReport.versionLine(app: Self.appVersion,
                                                               installedFX: Self.installedFXVersion)))
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

    /// Show the Lighting submenu unless the only Seiren we can see is a model
    /// with no Chroma zone. With nothing attached it stays visible (with its
    /// "applies when connected" caption) so a V3 Pro owner can pre-set it.
    private var lightingApplies: Bool {
        lighting.deviceConnected || lighting.attachedModel?.chromaLighting != false
    }

    /// Top-level helper for `.needsFX`: the attached mic has no headphone jack
    /// and Seiren FX isn't installed, so nothing can run yet. Says why in one
    /// line and puts the install action where the user is already looking.
    private func addNeedsFXItems(to menu: NSMenu) {
        menu.addItem(disabledItem("This mic has no headphone jack - it works through Seiren FX"))
        if DriverInstaller.isBundled {
            let install = NSMenuItem(title: "Install Seiren FX…",
                                     action: #selector(installDriver), keyEquivalent: "")
            install.target = self
            menu.addItem(install)
        } else {
            menu.addItem(disabledItem("Install Seiren FX first (scripts/install-driver.sh)"))
        }
    }

    private func modeItem(_ title: String, _ mode: MonitorEngine.Mode) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(selectMode(_:)), keyEquivalent: "")
        item.target = self
        item.state = (engine.mode == mode) ? .on : .off
        item.representedObject = mode.rawValue
        return item
    }

    private func inputMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Input", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let automatic = NSMenuItem(title: "Automatic", action: #selector(selectInput(_:)), keyEquivalent: "")
        automatic.target = self
        automatic.state = engine.inputPreference == .automatic ? .on : .off
        submenu.addItem(automatic)
        submenu.addItem(disabledItem("Seiren first, then your default mic"))
        submenu.addItem(.separator())
        let fxAvailable = engine.fxAvailable
        for input in engine.availableInputs {
            let choice = NSMenuItem(title: input.name, action: #selector(selectInput(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = input.uid
            choice.state = engine.inputPreference == .device(uid: input.uid) ? .on : .off
            choice.isEnabled = input.isSeiren || (fxAvailable && engine.otherInputsSupported)
            submenu.addItem(choice)
        }
        if case .device(let uid) = engine.inputPreference,
           !engine.availableInputs.contains(where: { $0.uid == uid }) {
            let name = settings.inputSourceName ?? uid
            let missing = disabledItem("\(name) (not connected)")
            missing.state = .on
            submenu.addItem(missing)
        }
        if !engine.otherInputsSupported {
            submenu.addItem(disabledItem("Other mics need macOS 14 or later"))
        } else if !fxAvailable {
            submenu.addItem(disabledItem("Other mics need Seiren FX (see Voice)"))
        }
        item.submenu = submenu
        return item
    }

    /// The "Voice ▸" submenu: EQ on/off + a preset picker, with an honest caption
    /// about where the EQ is heard. When the SeirenFX driver isn't installed, the
    /// EQ can't reach anything, so we say so instead of offering dead controls.
    private func voiceMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        // We manage enabled-state ourselves (presets gray out when the EQ is
        // off); without this AppKit auto-enables any item with a valid action
        // and ignores our `isEnabled`.
        submenu.autoenablesItems = false

        let fxAvailable = engine.fxAvailable
        let updateAvailable = DriverInstaller.updateAvailable
        let needsReinstall = engine.fxNeedsReinstall
        if needsReinstall {
            submenu.addItem(disabledItem("Seiren FX needs a one-time reinstall"))
        }
        if DriverInstaller.isBundled && (updateAvailable || needsReinstall) {
            let update = NSMenuItem(title: needsReinstall ? "Reinstall Seiren FX…" : "Update Seiren FX…",
                                    action: #selector(installDriver), keyEquivalent: "")
            update.target = self
            submenu.addItem(update)
            submenu.addItem(disabledItem(needsReinstall
                ? "Removes Seiren FX from speaker lists" : "A newer Seiren FX comes with this app"))
            if fxAvailable { submenu.addItem(.separator()) }
        } else if needsReinstall {
            submenu.addItem(disabledItem("Run scripts/build-driver.sh"))
            submenu.addItem(disabledItem("then sudo scripts/install-driver.sh"))
        }

        if !fxAvailable {
            if DriverInstaller.isBundled && !updateAvailable {
                let install = NSMenuItem(title: "Install Seiren FX…",
                                         action: #selector(installDriver), keyEquivalent: "")
                install.target = self
                install.isEnabled = true
                submenu.addItem(install)
                submenu.addItem(disabledItem("Enables EQ in OBS / Zoom / Discord"))
            } else if !DriverInstaller.isBundled {
                submenu.addItem(disabledItem("Build the Seiren FX driver to use EQ"))
                submenu.addItem(disabledItem("(see the README — scripts/build-driver.sh)"))
            }
        } else {
            let toggle = NSMenuItem(title: "Equalizer",
                                    action: #selector(toggleEQ), keyEquivalent: "")
            toggle.target = self
            toggle.isEnabled = true
            toggle.state = engine.eqEnabled ? .on : .off
            submenu.addItem(toggle)

            submenu.addItem(.separator())
            // Presets are only meaningful with the EQ on, so gray them out when
            // it's off — making it obvious you flip "Equalizer" first.
            let presetsHeader = disabledItem(engine.eqEnabled ? "Preset" : "Preset (turn on Equalizer)")
            submenu.addItem(presetsHeader)
            for preset in EQPreset.builtIns {
                let p = NSMenuItem(title: preset.name,
                                   action: #selector(selectEQPreset(_:)), keyEquivalent: "")
                p.target = self
                p.state = (engine.eqPreset.name == preset.name) ? .on : .off
                p.representedObject = preset.name
                p.isEnabled = engine.eqEnabled
                submenu.addItem(p)
            }
            submenu.addItem(.separator())
            submenu.addItem(disabledItem("Noise suppression"))
            submenu.addItem(nsItem("Off", .off))
            submenu.addItem(nsItem("Reduce noise (gate)", .gate))
            let studio = nsItem("Studio Denoise (RNNoise)", .studio)
            studio.isEnabled = engine.studioAvailable
            submenu.addItem(studio)
            if engine.noiseSuppression == .studio {
                // The "monitor stays low-latency" reassurance only means
                // something when there is a monitor.
                submenu.addItem(disabledItem(engine.deviceHasHeadphoneOutput
                    ? "Studio: removes steady noise · your monitor stays low-latency"
                    : "Studio: removes steady noise · adds ~10 ms to Seiren FX"))
            }

            submenu.addItem(.separator())
            submenu.addItem(disabledItem(eqReachCaption()))
        }

        item.submenu = submenu
        return item
    }

    private func streamMixerMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Stream Mixer", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.delegate = self
        mixerMenu = submenu
        populateMixerMenu(submenu)
        item.submenu = submenu
        return item
    }

    private func populateMixerMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        mixerRows = []
        displayedMixerState = mixerMenuState
        switch mixer.availability {
        case .needsFX, .needsDriverUpdate:
            let updating = mixer.availability == .needsDriverUpdate
            if DriverInstaller.isBundled {
                let install = NSMenuItem(title: updating ? "Update Seiren FX…" : "Install Seiren FX…",
                                         action: #selector(installDriver), keyEquivalent: "")
                install.target = self
                menu.addItem(install)
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
        let apps = NSMenu()
        apps.autoenablesItems = false
        if appChannels.count >= MixerEngine.maxAppChannels {
            apps.addItem(disabledItem("Up to 6 apps"))
        } else {
            let candidates = NSWorkspace.shared.runningApplications.filter { app in
                guard app.activationPolicy == .regular, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                      let id = app.bundleIdentifier, !MixerEngine.isWebAppShim(bundleID: id) else { return false }
                return id != Bundle.main.bundleIdentifier && !appChannels.contains { $0.source == .app(bundleID: id) }
            }.sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
            var seen: Set<String> = []
            for app in candidates {
                guard let id = app.bundleIdentifier, seen.insert(id).inserted else { continue }
                let choice = NSMenuItem(title: app.localizedName ?? id,
                                        action: #selector(addMixerApp(_:)), keyEquivalent: "")
                choice.target = self
                choice.representedObject = id
                choice.image = sizedMixerIcon(app.icon)
                apps.addItem(choice)
            }
        }
        add.submenu = apps
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
            menu.addItem(disabledItem(Self.coreAudioErrorLine(code)))
            let retry = NSMenuItem(title: "Try Again", action: #selector(retryMixer), keyEquivalent: "")
            retry.target = self
            menu.addItem(retry)
        default: menu.addItem(disabledItem("Starts when an app records Seiren Stream Mix"))
        }
        if engine.mode == .off { menu.addItem(disabledItem("Voice is silent while monitoring is Off")) }
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

    /// The "Lighting ▸" submenu: effect picker, static colors, brightness.
    /// Choices apply immediately when the mic is attached and are re-asserted
    /// on every replug (device lighting state is volatile). Until the user
    /// picks something, the device's own lighting is left untouched.
    private func lightingMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Lighting", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        if lighting.lastError == .permissionDenied {
            submenu.addItem(disabledItem("Lighting needs Input Monitoring access"))
            let open = NSMenuItem(title: "Open Input Monitoring Settings…",
                                  action: #selector(openInputMonitoringSettings),
                                  keyEquivalent: "")
            open.target = self
            open.isEnabled = true
            submenu.addItem(open)
            submenu.addItem(.separator())
        } else if !lighting.deviceConnected {
            submenu.addItem(disabledItem("Applies when the Seiren is connected"))
            submenu.addItem(.separator())
        }

        let current = settings.lightingState

        func effectItem(_ title: String, _ effect: ChromaEffect) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: #selector(selectLightingEffect(_:)),
                               keyEquivalent: "")
            i.target = self
            i.isEnabled = true
            i.state = (current?.effect == effect) ? .on : .off
            i.representedObject = Int(effect.rawValue)
            return i
        }

        submenu.addItem(effectItem("Spectrum (device default)", .spectrum))
        submenu.addItem(effectItem("Breathing", .breathing))
        submenu.addItem(effectItem("Wave", .wave))

        // Static ▸ color palette.
        let staticItem = NSMenuItem(title: "Static", action: nil, keyEquivalent: "")
        staticItem.state = (current?.effect == .static) ? .on : .off
        let colors = NSMenu()
        colors.autoenablesItems = false
        for (name, hex) in Self.lightingPalette {
            let c = NSMenuItem(title: name, action: #selector(selectLightingColor(_:)),
                               keyEquivalent: "")
            c.target = self
            c.isEnabled = true
            c.state = (current?.effect == .static && current?.color?.hex == hex) ? .on : .off
            c.representedObject = hex
            c.image = swatch(hex: hex)
            colors.addItem(c)
        }
        staticItem.submenu = colors
        submenu.addItem(staticItem)

        submenu.addItem(effectItem("Off", .off))

        submenu.addItem(.separator())
        submenu.addItem(lightingBrightnessItem())

        if lighting.lastError != nil, lighting.lastError != .permissionDenied {
            submenu.addItem(.separator())
            submenu.addItem(disabledItem("Couldn't reach the mic's lighting — replug and retry"))
        }

        item.submenu = submenu
        return item
    }

    /// A small filled-circle color swatch for the palette items.
    private func swatch(hex: String) -> NSImage? {
        guard let rgb = RGB(hex: hex) else { return nil }
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let color = NSColor(srgbRed: CGFloat(rgb.r) / 255,
                                green: CGFloat(rgb.g) / 255,
                                blue: CGFloat(rgb.b) / 255, alpha: 1)
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        return image
    }

    private func lightingBrightnessItem() -> NSMenuItem {
        Self.lightingBrightnessItem(percent: settings.lightingState?.brightnessPercent ?? 100, target: self)
    }

    static func lightingBrightnessItem(percent: Int, target: AnyObject?) -> NSMenuItem {
        let slider = PercentSlider(value: Double(percent),
                                   minValue: 0, maxValue: 100,
                                   target: target, action: #selector(lightingBrightnessChanged(_:)))
        // Not continuous: each change talks to the device, so send on release.
        slider.isContinuous = false
        slider.isEnabled = true
        return sliderItem(caption: "Brightness", label: "Lighting brightness", slider: slider)
    }

    private func nsItem(_ title: String, _ ns: MonitorEngine.NoiseSuppression) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(selectNS(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        item.state = (engine.noiseSuppression == ns) ? .on : .off
        item.representedObject = ns.rawValue
        return item
    }

    /// Honest one-liner about where the EQ is actually heard right now.
    private func eqReachCaption() -> String {
        if engine.isRoutingThroughFX {
            return engine.deviceHasHeadphoneOutput
                ? "Heard in your monitor + apps recording “Seiren FX”"
                : "Heard by apps recording “Seiren FX”"
        }
        return engine.mode == .off
            ? "Turn monitoring on to apply the EQ"
            : "Applies once monitoring is active"
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

    private func volumeItem(enabled: Bool) -> NSMenuItem {
        let (item, slider) = Self.volumeItem(level: engine.level, enabled: enabled, target: self)
        self.levelSlider = slider
        return item
    }

    static func volumeItem(level: Float, enabled: Bool, target: AnyObject?) -> (item: NSMenuItem, slider: PercentSlider) {
        let slider = PercentSlider(value: Double(level),
                                   minValue: 0, maxValue: 1,
                                   target: target, action: #selector(levelChanged(_:)))
        slider.isContinuous = true
        slider.isEnabled = enabled
        return (sliderItem(caption: "Volume", label: "Headphone monitor volume", slider: slider), slider)
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

    private static func coreAudioErrorLine(_ code: OSStatus) -> String {
        "Core Audio error \(code)"
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func selectInput(_ sender: NSMenuItem) {
        let preference: MonitorEngine.InputPreference
        if let uid = sender.representedObject as? String {
            preference = .device(uid: uid)
            settings.inputSourceName = engine.availableInputs.first { $0.uid == uid }?.name
        } else {
            preference = .automatic
        }
        settings.inputPreference = preference
        engine.setInputPreference(preference)
        rebuildMenu()
        configureStatusButtonImage()
    }

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

    @objc private func levelChanged(_ sender: NSSlider) {
        engine.level = Float(sender.doubleValue)
        settings.level = Float(sender.doubleValue)
    }

    @objc private func toggleEQ() {
        engine.setEQEnabled(!engine.eqEnabled)
        settings.eqEnabled = engine.eqEnabled
        rebuildMenu()
    }

    @objc private func selectEQPreset(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let preset = EQPreset.builtIns.first(where: { $0.name == name }) else { return }
        engine.setEQPreset(preset)
        settings.eqPreset = preset
        rebuildMenu()
    }

    @objc private func selectNS(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let ns = MonitorEngine.NoiseSuppression(rawValue: raw) else { return }
        engine.setNoiseSuppression(ns)
        settings.noiseSuppression = ns
        rebuildMenu()
    }

    @objc private func selectLightingEffect(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int,
              let effect = ChromaEffect(rawValue: UInt8(clamping: raw)) else { return }
        var state = settings.lightingState
            ?? LightingState(effect: effect, brightnessPercent: 100)
        state.effect = effect
        applyLighting(state)
    }

    @objc private func selectLightingColor(_ sender: NSMenuItem) {
        guard let hex = sender.representedObject as? String,
              let color = RGB(hex: hex) else { return }
        var state = settings.lightingState
            ?? LightingState(effect: .static, brightnessPercent: 100)
        state.effect = .static
        state.color = color
        applyLighting(state)
    }

    @objc private func lightingBrightnessChanged(_ sender: NSSlider) {
        // Brightness alone shouldn't force an effect on an untouched device,
        // but a bare brightness with no effect is meaningless — default to the
        // device's own spectrum effect in that case.
        var state = settings.lightingState
            ?? LightingState(effect: .spectrum, brightnessPercent: 100)
        state.brightnessPercent = Int(sender.doubleValue)
        applyLighting(state)
    }

    private func applyLighting(_ state: LightingState) {
        settings.lightingState = state
        lighting.apply(state)
        rebuildMenu()
    }

    @objc private func systemDidWake() {
        systemAsleep = false
        updateStandbyAllowed()
        lighting.reassert()
    }

    @objc private func standbyConditionChanged(_ note: Notification) {
        switch note.name {
        case NSWorkspace.screensDidSleepNotification: screensAsleep = true
        case NSWorkspace.screensDidWakeNotification: screensAsleep = false
        case NSWorkspace.willSleepNotification: systemAsleep = true
        case NSWorkspace.sessionDidResignActiveNotification: sessionInactive = true
        case NSWorkspace.sessionDidBecomeActiveNotification: sessionInactive = false
        default: return
        }
        updateStandbyAllowed()
    }

    private func updateStandbyAllowed() {
        engine.setStandbyAllowed(!screensAsleep && !systemAsleep && !sessionInactive)
    }

    @objc private func openInputMonitoringSettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func installDriver() {
        switch DriverInstaller.install() {
        case .cancelled:
            return
        case .failed(let why):
            presentError("Couldn't install Seiren FX:\n\(why)\n\n" +
                         "You can also install it manually with scripts/install-driver.sh.")
            return
        case .ok:
            let alert = NSAlert()
            alert.messageText = "Seiren FX installed"
            alert.informativeText = "Audio was restarted. Turn on the Equalizer under " +
                "Voice, then choose “Seiren FX” as the microphone in OBS / Zoom / " +
                "Discord to send them your processed voice."
            alert.runModal()
            // coreaudiod just restarted: force a clean re-acquire so the engine
            // drops the now-dead IOProc and picks up the new Seiren FX device.
            let mode = engine.mode
            let mixing = mixer.isEnabled
            engine.setMode(.off)
            mixer.setEnabled(false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { return }
                self.engine.setMode(mode)
                self.mixer.setEnabled(mixing)
                self.engine.includeStreamMixInTriggers = self.mixer.isEnabled
                self.rebuildMenu()
            }
            rebuildMenu()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            presentError("Couldn't change Launch at Login: \(error.localizedDescription)")
        }
        rebuildMenu()
    }

    @objc private func openMicrophoneSettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func retryAudio() {
        engine.retryNow()
    }

    @objc private func copyDiagnostics() {
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
            updateOffered: DriverInstaller.isBundled && DriverInstaller.updateAvailable && !needsReinstall)
        let engineState = DiagnosticsSnapshot.Engine(
            mode: engine.mode, state: engine.state, inputPreference: engine.inputPreference,
            activeSource: engine.activeSource, routesThroughFX: engine.isRoutingThroughFX,
            standbyRunning: engine.isStandbyRunning, route: engine.routeDiagnostics,
            recordingBundleIDs: engine.recordingBundleIDs)
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
        // The event log (#24) does not exist yet, so there is no history to add.
        return DiagnosticsSnapshot(versions: versions, engine: engineState,
                                   devices: AudioDevices.diagnosticsDevices(), mixer: mixerState,
                                   lighting: lightingState, microphoneAccess: microphone,
                                   inputMonitoringAccess: inputMonitoring, history: [])
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

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
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

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Seiren"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// A slider that accessibility reads as a percentage of its range instead of the
/// raw value, so 0...1 and 0...100 sliders sound alike. Accessibility ignores an
/// NSSlider and exposes its cell, so the value description lives on the cell.
final class PercentSlider: NSSlider {
    override class var cellClass: AnyClass? {
        get { PercentSliderCell.self }
        set {}
    }
}

final class PercentSliderCell: NSSliderCell {
    override func accessibilityValueDescription() -> String? {
        let fraction = (doubleValue - minValue) / (maxValue - minValue)
        return "\(Int((fraction * 100).rounded()))%"
    }
}

/// Menu-hosted controls keep tracking without dismissing the menu. Slider and
/// mute actions update this row immediately; delegate updates reuse the view.
@MainActor
final class MixerChannelView: NSView {
    private(set) var channel: MixerEngine.Channel
    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let slider: PercentSlider
    private let mute = NSButton()
    private let changed: (MixerEngine.Channel) -> Void

    init(channel: MixerEngine.Channel, icon: NSImage?, changed: @escaping (MixerEngine.Channel) -> Void) {
        self.channel = channel
        self.changed = changed
        slider = PercentSlider(value: Double(channel.level), minValue: 0, maxValue: 1, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 44))
        autoresizingMask = [.width]   // the menu sizes the row to its own width
        let image = NSImageView(frame: NSRect(x: 14, y: 24, width: 16, height: 16))
        image.image = icon
        image.imageScaling = .scaleProportionallyDown
        addSubview(image)
        nameLabel.frame = NSRect(x: 36, y: 24, width: 108, height: 16)
        nameLabel.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.autoresizingMask = [.width]
        addSubview(nameLabel)
        valueLabel.frame = NSRect(x: 144, y: 24, width: 58, height: 16)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.autoresizingMask = [.minXMargin]
        addSubview(valueLabel)
        mute.frame = NSRect(x: 204, y: 22, width: 24, height: 20)
        mute.isBordered = false
        mute.imagePosition = .imageOnly
        mute.autoresizingMask = [.minXMargin]
        mute.target = self
        mute.action = #selector(toggleMute)
        addSubview(mute)
        slider.frame = NSRect(x: 14, y: 4, width: 212, height: 19)
        slider.autoresizingMask = [.width]
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(levelChanged)
        addSubview(slider)
        update(channel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ channel: MixerEngine.Channel) {
        self.channel = channel
        nameLabel.stringValue = channel.name
        valueLabel.stringValue = channel.muted ? "Muted" : "\(Int((channel.level * 100).rounded()))%"
        slider.doubleValue = Double(channel.level)
        // A muted channel keeps its level for when it comes back; dimming the
        // slider shows that it isn't reaching the stream right now.
        slider.alphaValue = channel.muted ? 0.4 : 1
        slider.cell?.setAccessibilityLabel("\(channel.name) level on stream")
        mute.image = NSImage(systemSymbolName: channel.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                             accessibilityDescription: nil)
        mute.toolTip = channel.muted ? "Unmute on stream" : "Mute on stream"
        mute.setAccessibilityLabel("\(channel.name): \(mute.toolTip ?? "")")
        mute.setAccessibilityValue(channel.muted ? "Muted" : "Unmuted")
    }

    @objc private func levelChanged() {
        channel.level = slider.floatValue
        update(channel)
        changed(channel)
    }

    @objc private func toggleMute() {
        channel.muted.toggle()
        update(channel)
        changed(channel)
    }
}
