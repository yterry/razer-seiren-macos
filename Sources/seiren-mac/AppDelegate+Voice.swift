import AppKit
import SeirenKit

extension AppDelegate {
    func inputMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: Strings.inputTitle, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let automatic = NSMenuItem(title: Strings.inputAutomatic, action: #selector(selectInput(_:)), keyEquivalent: "")
        automatic.target = self
        automatic.state = engine.inputPreference == .automatic ? .on : .off
        submenu.addItem(automatic)
        submenu.addItem(disabledItem(Strings.inputAutomaticHint))
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
            let missing = disabledItem(Strings.inputNotConnected(name))
            missing.state = .on
            submenu.addItem(missing)
        }
        if !engine.otherInputsSupported {
            submenu.addItem(disabledItem(Strings.inputNeedsMacOS14))
        } else if !fxAvailable {
            submenu.addItem(disabledItem(Strings.inputNeedsFX))
        }
        item.submenu = submenu
        return item
    }

    /// The "Voice ▸" submenu: EQ on/off + a preset picker, with an honest caption
    /// about where the EQ is heard. When the SeirenFX driver isn't installed, the
    /// EQ can't reach anything, so we say so instead of offering dead controls.
    func voiceMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: Strings.voiceTitle, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        // We manage enabled-state ourselves (presets gray out when the EQ is
        // off); without this AppKit auto-enables any item with a valid action
        // and ignores our `isEnabled`.
        submenu.autoenablesItems = false

        let fxAvailable = engine.fxAvailable
        // A bundled update or reinstall is offered at the top level of the menu.
        if engine.fxNeedsReinstall && !DriverInstaller.isBundled {
            submenu.addItem(disabledItem(Strings.driverNeedsReinstall))
            submenu.addItem(disabledItem(Strings.voiceRunBuildDriver))
            submenu.addItem(disabledItem(Strings.voiceThenInstallDriver))
        }

        if !fxAvailable {
            if DriverInstaller.isBundled {
                submenu.addItem(driverMenuItem(offeredDriverAction ?? .install))
                submenu.addItem(disabledItem(Strings.voiceEnablesEQ))
            } else {
                submenu.addItem(disabledItem(Strings.voiceBuildDriver))
                submenu.addItem(disabledItem(Strings.voiceSeeReadme))
            }
        } else {
            let toggle = NSMenuItem(title: Strings.voiceEqualizer,
                                    action: #selector(toggleEQ), keyEquivalent: "")
            toggle.target = self
            toggle.isEnabled = true
            toggle.state = engine.eqEnabled ? .on : .off
            submenu.addItem(toggle)

            submenu.addItem(.separator())
            // Presets are only meaningful with the EQ on, so gray them out when
            // it's off — making it obvious you flip "Equalizer" first.
            let presetsHeader = disabledItem(engine.eqEnabled ? Strings.voicePreset : Strings.voicePresetTurnOnEQ)
            submenu.addItem(presetsHeader)
            for preset in EQPreset.builtIns {
                let p = NSMenuItem(title: Strings.eqPresetName(preset),
                                   action: #selector(selectEQPreset(_:)), keyEquivalent: "")
                p.target = self
                p.state = (engine.eqPreset.name == preset.name) ? .on : .off
                p.representedObject = preset.name
                p.isEnabled = engine.eqEnabled
                submenu.addItem(p)
            }
            submenu.addItem(.separator())
            submenu.addItem(disabledItem(Strings.voiceNoiseSuppression))
            submenu.addItem(nsItem(Strings.voiceNoiseSuppressionOff, .off))
            submenu.addItem(nsItem(Strings.voiceNoiseSuppressionGate, .gate))
            let studio = nsItem(Strings.voiceNoiseSuppressionStudio, .studio)
            studio.isEnabled = engine.studioAvailable
            submenu.addItem(studio)
            if engine.noiseSuppression == .studio {
                // The "monitor stays low-latency" reassurance only means
                // something when there is a monitor.
                submenu.addItem(disabledItem(engine.deviceHasHeadphoneOutput
                    ? Strings.voiceStudioWithMonitor
                    : Strings.voiceStudioWithoutMonitor))
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
                ? Strings.voiceCaptionHeardInMonitor
                : Strings.voiceCaptionHeardByApps
        }
        if engine.fxRouteFailure != nil { return Strings.voiceCaptionFXFailed }
        return engine.mode == .off
            ? Strings.voiceCaptionTurnOnMonitoring
            : Strings.voiceCaptionAppliesWhenActive
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
        return (sliderItem(caption: Strings.volumeCaption, label: Strings.volumeLabel, slider: slider), slider)
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
