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
final class AppDelegate: NSObject, NSApplicationDelegate, MonitorEngineDelegate {

    // MARK: - State

    private var statusItem: NSStatusItem!
    private let engine = MonitorEngine(deviceNameMatch: "seiren")
    private let settings = Settings()
    private var levelSlider: NSSlider?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusButtonImage()

        engine.delegate = self

        // Restore persisted level + EQ + noise suppression before auto-resume.
        if let lvl = settings.level { engine.level = lvl }
        engine.setEQPreset(settings.eqPreset)
        engine.setEQEnabled(settings.eqEnabled)
        engine.setNoiseSuppression(settings.noiseSuppression)

        rebuildMenu()

        // Restore the saved mode (migrating the pre-mode Bool if present). If
        // monitoring should be on, request mic access first so a previously
        // granted user keeps working and a fresh user gets the prompt once.
        let restored = restoredMode()
        if restored == .off {
            engine.setMode(.off)
        } else {
            requestMicrophoneAccessThen { [weak self] in self?.engine.setMode(restored) }
        }
    }

    private func restoredMode() -> MonitorEngine.Mode {
        // Settings.migrate() already upgraded the pre-mode Bool to a mode string.
        settings.mode
    }

    // MARK: - MonitorEngineDelegate

    nonisolated func monitorEngineDidChange(_ engine: MonitorEngine) {
        Task { @MainActor in
            self.rebuildMenu()
            self.configureStatusButtonImage()
        }
    }

    // MARK: - Status item icon

    /// A mic glyph: bright with a waveform while actively monitoring, plain mic
    /// while armed/idle, dimmed when off. Template-rendered for light/dark bars.
    private func configureStatusButtonImage() {
        guard let button = statusItem.button else { return }
        let running = engine.state == .running
        let symbol = running ? "waveform.and.mic" : "mic"
        let image = NSImage(systemSymbolName: symbol,
                            accessibilityDescription: "Seiren monitoring")
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = (engine.mode == .off)
        button.toolTip = statusLine()
    }

    // MARK: - Menu construction

    private func rebuildMenu() {
        let menu = NSMenu()

        // 1. Device / state line (disabled, informational).
        menu.addItem(disabledItem(statusLine()))

        // 2. Permission helper, only when denied.
        if engine.state == .permissionDenied {
            menu.addItem(disabledItem("Microphone access is required"))
            let open = NSMenuItem(title: "Open Microphone Settings…",
                                  action: #selector(openMicrophoneSettings),
                                  keyEquivalent: "")
            open.target = self
            menu.addItem(open)
        }

        menu.addItem(.separator())

        // 3. Mode — three mutually-exclusive choices (radio-style checkmarks).
        menu.addItem(modeItem("Off", .off))
        menu.addItem(modeItem("On — always", .always))
        let auto = modeItem("Auto — only while an app uses the mic", .auto)
        menu.addItem(auto)

        menu.addItem(.separator())

        // 4. Volume — an embedded NSSlider. Enabled whenever monitoring isn't off.
        menu.addItem(volumeItem(enabled: engine.mode != .off))

        menu.addItem(.separator())

        // 5. Voice — parametric EQ (creator path; needs SeirenFX).
        menu.addItem(voiceMenuItem())

        menu.addItem(.separator())

        // 6. Launch at login (SMAppService, macOS 13+).
        let login = NSMenuItem(title: "Launch at Login",
                               action: #selector(toggleLaunchAtLogin),
                               keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        // 6. Quit.
        let quit = NSMenuItem(title: "Quit Seiren",
                              action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func modeItem(_ title: String, _ mode: MonitorEngine.Mode) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(selectMode(_:)), keyEquivalent: "")
        item.target = self
        item.state = (engine.mode == mode) ? .on : .off
        item.representedObject = mode.rawValue
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

        if !engine.fxAvailable {
            if DriverInstaller.isBundled {
                let install = NSMenuItem(title: "Install Seiren FX…",
                                         action: #selector(installDriver), keyEquivalent: "")
                install.target = self
                install.isEnabled = true
                submenu.addItem(install)
                submenu.addItem(disabledItem("Enables EQ in OBS / Zoom / Discord"))
            } else {
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
                submenu.addItem(disabledItem("Studio: removes steady noise · your monitor stays low-latency"))
            }

            submenu.addItem(.separator())
            submenu.addItem(disabledItem(eqReachCaption()))
        }

        item.submenu = submenu
        return item
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
            return "Heard in your monitor + apps recording “Seiren FX”"
        }
        return engine.mode == .off
            ? "Turn monitoring on to apply the EQ"
            : "Applies once monitoring is active"
    }

    /// Human-readable device + state line for the top of the menu / tooltip.
    private func statusLine() -> String {
        switch engine.state {
        case .running:
            return "Monitoring: \(engine.connectedDeviceName ?? "Seiren")"
        case .waiting:
            return "Auto: waiting for an app to use the mic"
        case .noDevice:
            return "No Seiren detected"
        case .permissionDenied:
            return "Microphone access denied"
        case .failed(let code):
            return String(format: "Audio error (%d)", code)
        case .stopped:
            return engine.connectedDeviceName.map { "Ready: \($0)" } ?? "Monitoring off"
        }
    }

    /// A menu item hosting an NSSlider with a small label.
    private func volumeItem(enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))

        let label = NSTextField(labelWithString: "Volume")
        label.frame = NSRect(x: 14, y: 22, width: 100, height: 14)
        label.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        container.addSubview(label)

        let slider = NSSlider(value: Double(engine.level),
                              minValue: 0, maxValue: 1,
                              target: self, action: #selector(levelChanged(_:)))
        slider.frame = NSRect(x: 14, y: 4, width: 212, height: 19)
        slider.isContinuous = true
        slider.isEnabled = enabled
        slider.toolTip = "Headphone monitor volume"
        container.addSubview(slider)

        self.levelSlider = slider
        item.view = container
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
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
            requestMicrophoneAccessThen { [weak self] in
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
            engine.setMode(.off)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { return }
                self.engine.setMode(mode)
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

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Microphone permission

    /// Ensure the prompt has been shown and run `onGranted` if access is (or
    /// becomes) authorized. On denial we still call through so the engine can
    /// surface `.permissionDenied` with the Settings shortcut.
    private func requestMicrophoneAccessThen(_ onGranted: @escaping @MainActor () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            onGranted()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    if granted { onGranted() } else { self.rebuildMenu() }
                }
            }
        case .denied, .restricted:
            onGranted()
        @unknown default:
            onGranted()
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
