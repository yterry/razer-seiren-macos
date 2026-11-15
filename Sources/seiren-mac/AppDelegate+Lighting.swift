import AppKit
import SeirenKit

extension AppDelegate {
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

    /// Show the Lighting submenu unless the only Seiren we can see is a model
    /// with no Chroma zone. With nothing attached it stays visible (with its
    /// "applies when connected" caption) so a V3 Pro owner can pre-set it.
    var lightingApplies: Bool {
        lighting.deviceConnected || lighting.attachedModel?.chromaLighting != false
    }

    /// The "Lighting ▸" submenu: effect picker, static colors, brightness.
    /// Choices apply immediately when the mic is attached and are re-asserted
    /// on every replug (device lighting state is volatile). Until the user
    /// picks something, the device's own lighting is left untouched.
    func lightingMenuItem() -> NSMenuItem {
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

    @objc private func openInputMonitoringSettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}
