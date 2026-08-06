import Foundation
import SeirenKit

/// Typed, versioned wrapper over `UserDefaults`. Centralizes the app's settings
/// keys and migrations so features can add settings without scattering string
/// keys, and so old installs upgrade cleanly. See docs/CREATOR_DESIGN.md §6.2.
@MainActor
final class Settings {

    private let defaults: UserDefaults

    private enum Key {
        static let schemaVersion = "schemaVersion"
        static let mode          = "monitorMode"        // MonitorEngine.Mode.rawValue
        static let level         = "monitorLevel"       // Double 0...1
        static let eqEnabled     = "voice.eq.enabled"   // Bool
        static let eqPreset      = "voice.eq.preset"    // EQPreset.name
        static let nsMode        = "voice.ns.mode"      // NoiseSuppression.rawValue
        static let legacyEnabled = "monitoringEnabled"  // pre-mode Bool (v0)
        static let lightEffect   = "lighting.effect"    // ChromaEffect.rawValue (Int)
        static let lightColor    = "lighting.color"     // "RRGGBB"
        static let lightLevel    = "lighting.brightness" // Int 0...100
    }

    /// Bump when adding a migration. v1 = mode strings; v2 = EQ keys;
    /// v3 = lighting keys (absence = "never touched the lights");
    /// v4 = brand-green -> LED-green fixup.
    static let currentSchema = 4

    init(_ defaults: UserDefaults = .standard) {
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
        // is nothing to migrate — just record the new schema version.
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

        defaults.set(Self.currentSchema, forKey: Key.schemaVersion)
    }

    // MARK: Monitoring

    var mode: MonitorEngine.Mode {
        get { defaults.string(forKey: Key.mode).flatMap(MonitorEngine.Mode.init(rawValue:)) ?? .off }
        set { defaults.set(newValue.rawValue, forKey: Key.mode) }
    }

    /// Persisted monitor level, or nil if the user never set one.
    var level: Float? {
        get { defaults.object(forKey: Key.level) == nil ? nil : Float(defaults.double(forKey: Key.level)) }
        set { if let v = newValue { defaults.set(Double(v), forKey: Key.level) } }
    }

    // MARK: EQ

    var eqEnabled: Bool {
        get { defaults.bool(forKey: Key.eqEnabled) }
        set { defaults.set(newValue, forKey: Key.eqEnabled) }
    }

    /// The persisted preset, resolved to a built-in (falls back to Flat).
    var eqPreset: EQPreset {
        get {
            let name = defaults.string(forKey: Key.eqPreset) ?? EQPreset.flat.name
            return EQPreset.builtIns.first { $0.name == name } ?? .flat
        }
        set { defaults.set(newValue.name, forKey: Key.eqPreset) }
    }

    var noiseSuppression: MonitorEngine.NoiseSuppression {
        get {
            defaults.string(forKey: Key.nsMode)
                .flatMap(MonitorEngine.NoiseSuppression.init(rawValue:)) ?? .off
        }
        set { defaults.set(newValue.rawValue, forKey: Key.nsMode) }
    }

    // MARK: Lighting

    /// The user's lighting choice, or nil if they never set one — in which case
    /// the app must not touch the device's lights at all.
    var lightingState: LightingState? {
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
