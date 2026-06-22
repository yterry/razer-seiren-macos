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
    }

    /// Bump when adding a migration. v1 = mode strings; v2 = EQ keys.
    static let currentSchema = 2

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
}
