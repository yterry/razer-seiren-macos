import Foundation

/// Typed, versioned wrapper over `UserDefaults`. Centralizes the app's settings
/// keys and migrations so features can add settings without scattering string
/// keys, and so old installs upgrade cleanly. See docs/CREATOR_DESIGN.md §6.2.
@MainActor
public final class Settings {

    private let defaults: UserDefaults

    private enum Key {
        static let schemaVersion = "schemaVersion"
        static let mode          = "monitorMode"        // MonitorEngine.Mode.rawValue
        static let inputSource   = "input.source"
        static let inputName     = "input.sourceName"
        static let level         = "monitorLevel"       // Double 0...1
        static let eqEnabled     = "voice.eq.enabled"   // Bool
        static let eqPreset      = "voice.eq.preset"    // EQPreset.name
        static let nsMode        = "voice.ns.mode"      // NoiseSuppression.rawValue
        static let mixerEnabled  = "mixer.enabled"
        static let mixerChannels = "mixer.channels"
        static let legacyEnabled = "monitoringEnabled"  // pre-mode Bool (v0)
        static let lightEffect   = "lighting.effect"    // ChromaEffect.rawValue (Int)
        static let lightColor    = "lighting.color"     // "RRGGBB"
        static let lightLevel    = "lighting.brightness" // Int 0...100
        static let autoStandby   = "auto.standbyEnabled" // Bool, set with `defaults write`
        static let firstRunDone  = "firstRun.done"      // Bool
        static let updateCheck   = "updates.checkEnabled" // Bool, set with `defaults write`
        static let crashSeenAt   = "crashReport.seenAt" // Date
    }

    /// Bump when adding a migration. v1 = mode strings; v2 = EQ keys;
    /// v3 = lighting keys (absence = "never touched the lights");
    /// v4 = brand-green -> LED-green fixup; v5 = input preference (absence = automatic); v6 = mixer (absence = defaults);
    /// v7 = first-run flag (set for installs that already ran an earlier version).
    public static let currentSchema = 7

    public init(_ defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrate()
    }

    private func migrate() {
        let from = defaults.integer(forKey: Key.schemaVersion)
        guard from < Self.currentSchema else { return }

        if from < 1 {
            // v0 → v1: the old Bool "monitoringEnabled" becomes a mode string.
            if defaults.string(forKey: Key.mode) == nil,
               defaults.bool(forKey: Key.legacyEnabled) {
                defaults.set(MonitorEngine.Mode.always.rawValue, forKey: Key.mode)
            }
        }
        // v1 → v2: EQ keys added; their absence reads as "off / Flat", so there
        // is nothing to migrate - just record the new schema version.
        // v2 → v3: lighting keys added; absence means "leave the device's
        // lighting alone", so again nothing to migrate.

        if from < 4 {
            // v3 → v4: the palette's "Razer Green" briefly stored the brand
            // hex 44D62C, which renders washed-out on the LEDs; rewrite it to
            // the LED green the palette now sends.
            if defaults.string(forKey: Key.lightColor)?.uppercased() == "44D62C" {
                defaults.set("00FF00", forKey: Key.lightColor)
            }
        }

        if from < 7 {
            // v6 → v7: the first-launch welcome is for new installs only. A
            // stored schema version, mode or pre-mode Bool means an earlier
            // version already ran here, so its first run is long over.
            if from > 0 || defaults.object(forKey: Key.mode) != nil
                || defaults.object(forKey: Key.legacyEnabled) != nil {
                defaults.set(true, forKey: Key.firstRunDone)
            }
        }

        defaults.set(Self.currentSchema, forKey: Key.schemaVersion)
    }

    // MARK: First run

    /// False on a new install until the first-launch welcome has been answered.
    public var firstRunDone: Bool {
        get { defaults.bool(forKey: Key.firstRunDone) }
        set { defaults.set(newValue, forKey: Key.firstRunDone) }
    }

    // MARK: Crash reports

    /// When the user last acted on the "quit unexpectedly" menu section. Crash
    /// reports from before it are not offered again; nil offers any report.
    public var crashReportSeenAt: Date? {
        get { defaults.object(forKey: Key.crashSeenAt) as? Date }
        set { defaults.set(newValue, forKey: Key.crashSeenAt) }
    }

    // MARK: Monitoring

    public var mode: MonitorEngine.Mode {
        get { defaults.string(forKey: Key.mode).flatMap(MonitorEngine.Mode.init(rawValue:)) ?? .off }
        set { defaults.set(newValue.rawValue, forKey: Key.mode) }
    }

    public var inputPreference: MonitorEngine.InputPreference {
        get {
            guard let uid = defaults.string(forKey: Key.inputSource), uid != "automatic" else {
                return .automatic
            }
            return .device(uid: uid)
        }
        set {
            switch newValue {
            case .automatic: defaults.set("automatic", forKey: Key.inputSource)
            case .device(let uid): defaults.set(uid, forKey: Key.inputSource)
            }
        }
    }

    public var inputSourceName: String? {
        get { defaults.string(forKey: Key.inputName) }
        set { defaults.set(newValue, forKey: Key.inputName) }
    }

    /// Whether Auto keeps the Seiren's headphone output running between calls.
    /// There is no menu item; absence reads as on.
    public var autoStandbyEnabled: Bool {
        defaults.object(forKey: Key.autoStandby) == nil ? true : defaults.bool(forKey: Key.autoStandby)
    }

    // MARK: Updates

    /// Whether the app asks GitHub for the latest release. There is no menu
    /// item; absence reads as on.
    public var updateCheckEnabled: Bool {
        defaults.object(forKey: Key.updateCheck) == nil ? true : defaults.bool(forKey: Key.updateCheck)
    }

    /// Persisted monitor level, or nil if the user never set one.
    public var level: Float? {
        get { defaults.object(forKey: Key.level) == nil ? nil : Float(defaults.double(forKey: Key.level)) }
        set { if let v = newValue { defaults.set(Double(v), forKey: Key.level) } }
    }

    // MARK: EQ

    public var eqEnabled: Bool {
        get { defaults.bool(forKey: Key.eqEnabled) }
        set { defaults.set(newValue, forKey: Key.eqEnabled) }
    }

    /// The persisted preset, resolved to a built-in (falls back to Flat).
    public var eqPreset: EQPreset {
        get {
            let name = defaults.string(forKey: Key.eqPreset) ?? EQPreset.flat.name
            return EQPreset.builtIns.first { $0.name == name } ?? .flat
        }
        set { defaults.set(newValue.name, forKey: Key.eqPreset) }
    }

    public var noiseSuppression: MonitorEngine.NoiseSuppression {
        get {
            defaults.string(forKey: Key.nsMode)
                .flatMap(MonitorEngine.NoiseSuppression.init(rawValue:)) ?? .off
        }
        set { defaults.set(newValue.rawValue, forKey: Key.nsMode) }
    }

    // MARK: Stream Mixer

    public var mixerEnabled: Bool {
        get { defaults.bool(forKey: Key.mixerEnabled) }
        set { defaults.set(newValue, forKey: Key.mixerEnabled) }
    }

    public var mixerChannels: [MixerEngine.Channel] {
        get {
            guard let data = defaults.data(forKey: Key.mixerChannels),
                  let channels = try? JSONDecoder().decode([MixerEngine.Channel].self, from: data)
            else { return MixerEngine.defaultChannels }
            return MixerEngine.normalizedChannels(channels)
        }
        set {
            if let data = try? JSONEncoder().encode(MixerEngine.normalizedChannels(newValue)) {
                defaults.set(data, forKey: Key.mixerChannels)
            }
        }
    }

    // MARK: Lighting

    /// The user's lighting choice, or nil if they never set one - in which case
    /// the app must not touch the device's lights at all.
    public var lightingState: LightingState? {
        get {
            guard defaults.object(forKey: Key.lightEffect) != nil,
                  let effect = ChromaEffect(rawValue: UInt8(clamping: defaults.integer(forKey: Key.lightEffect)))
            else { return nil }
            let color = defaults.string(forKey: Key.lightColor).flatMap(RGB.init(hex:))
            let level = defaults.object(forKey: Key.lightLevel) == nil
                ? 100 : defaults.integer(forKey: Key.lightLevel)
            return LightingState(effect: effect, color: color, brightnessPercent: level)
        }
        set {
            guard let state = newValue else {
                defaults.removeObject(forKey: Key.lightEffect)
                defaults.removeObject(forKey: Key.lightColor)
                defaults.removeObject(forKey: Key.lightLevel)
                return
            }
            defaults.set(Int(state.effect.rawValue), forKey: Key.lightEffect)
            if let c = state.color { defaults.set(c.hex, forKey: Key.lightColor) }
            defaults.set(state.brightnessPercent, forKey: Key.lightLevel)
        }
    }
}
