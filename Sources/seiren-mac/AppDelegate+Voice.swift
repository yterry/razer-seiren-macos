import AppKit
import SeirenKit

extension AppDelegate {
    func inputMenuItem() -> NSMenuItem {
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
    func voiceMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        // We manage enabled-state ourselves (presets gray out when the EQ is
        // off); without this AppKit auto-enables any item with a valid action
        // and ignores our `isEnabled`.
        submenu.autoenablesItems = false

        let fxAvailable = engine.fxAvailable
        // A bundled update or reinstall is offered at the top level of the menu.
        if engine.fxNeedsReinstall && !DriverInstaller.isBundled {
            submenu.addItem(disabledItem("Seiren FX needs a one-time reinstall"))
            submenu.addItem(disabledItem("Run scripts/build-driver.sh"))
            submenu.addItem(disabledItem("then sudo scripts/install-driver.sh"))
        }

        if !fxAvailable {
            if DriverInstaller.isBundled {
                submenu.addItem(driverMenuItem(offeredDriverAction ?? .install))
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
                // The "monitor stays low-latency" reassurance only means
                // something when there is a monitor.
                submenu.addItem(disabledItem(engine.deviceHasHeadphoneOutput
                    ? "Studio: removes steady noise · your monitor stays low-latency"
                    : "Studio: removes steady noise · adds ~10 ms to Seiren FX"))
            }

            submenu.addItem(.separator())
            submenu.addItem(disabledItem(eqReachCaption()))
        }

        if DriverInstaller.isInstalled {
            submenu.addItem(.separator())
            submenu.addItem(driverMenuItem(.uninstall))
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
            return engine.deviceHasHeadphoneOutput
                ? "Heard in your monitor + apps recording “Seiren FX”"
                : "Heard by apps recording “Seiren FX”"
        }
        if engine.fxRouteFailure != nil { return "Seiren FX couldn't start - the EQ isn't applied" }
        return engine.mode == .off
            ? "Turn monitoring on to apply the EQ"
            : "Applies once monitoring is active"
    }

    func volumeItem(enabled: Bool) -> NSMenuItem {
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
}
