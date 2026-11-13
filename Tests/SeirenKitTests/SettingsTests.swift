import Foundation
import XCTest
import SeirenKit

@MainActor
final class SettingsTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "SeirenKitTests.SettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    func testFreshInstallDefaults() throws {
        let defaults = try makeDefaults()
        let settings = Settings(defaults)

        XCTAssertEqual(settings.mode, .off)
        XCTAssertEqual(settings.inputPreference, .automatic)
        XCTAssertNil(settings.inputSourceName)
        XCTAssertNil(settings.level)
        XCTAssertFalse(settings.eqEnabled)
        XCTAssertEqual(settings.eqPreset, .flat)
        XCTAssertEqual(settings.noiseSuppression, .off)
        XCTAssertFalse(settings.mixerEnabled)
        XCTAssertEqual(settings.mixerChannels, MixerEngine.defaultChannels)
        XCTAssertNil(settings.lightingState)
        XCTAssertEqual(defaults.integer(forKey: "schemaVersion"), Settings.currentSchema)
    }

    func testVersionZeroMigratesEnabledMonitoringToAlways() throws {
        let defaults = try makeDefaults()
        defaults.set(true, forKey: "monitoringEnabled")

        XCTAssertEqual(Settings(defaults).mode, .always)
        XCTAssertEqual(defaults.string(forKey: "monitorMode"), "always")
        XCTAssertEqual(defaults.integer(forKey: "schemaVersion"), Settings.currentSchema)
    }

    func testVersionZeroPreservesExistingMode() throws {
        let defaults = try makeDefaults()
        defaults.set(true, forKey: "monitoringEnabled")

        for mode in ["off", "auto", "always", "future-mode"] {
            defaults.set(0, forKey: "schemaVersion")
            defaults.set(mode, forKey: "monitorMode")

            _ = Settings(defaults)

            XCTAssertEqual(defaults.string(forKey: "monitorMode"), mode)
            XCTAssertEqual(defaults.integer(forKey: "schemaVersion"), Settings.currentSchema)
        }
    }

    func testVersionFourMigrationReplacesBrandGreenInAnyLetterCase() throws {
        let defaults = try makeDefaults()

        for color in ["44D62C", "44d62c", "44D62c", "44d62C"] {
            defaults.set(3, forKey: "schemaVersion")
            defaults.set(color, forKey: "lighting.color")

            _ = Settings(defaults)

            XCTAssertEqual(defaults.string(forKey: "lighting.color"), "00FF00", color)
            XCTAssertEqual(defaults.integer(forKey: "schemaVersion"), Settings.currentSchema)
        }
    }

    func testVersionFourMigrationPreservesOtherColors() throws {
        let defaults = try makeDefaults()

        for color in ["00FF00", "aBcDeF", "FF0000"] {
            defaults.set(3, forKey: "schemaVersion")
            defaults.set(color, forKey: "lighting.color")

            _ = Settings(defaults)

            XCTAssertEqual(defaults.string(forKey: "lighting.color"), color)
        }
    }

    func testVersionFourDoesNotRepeatColorMigration() throws {
        let defaults = try makeDefaults()
        defaults.set(4, forKey: "schemaVersion")
        defaults.set("44D62C", forKey: "lighting.color")

        _ = Settings(defaults)

        XCTAssertEqual(defaults.string(forKey: "lighting.color"), "44D62C")
        XCTAssertEqual(defaults.integer(forKey: "schemaVersion"), Settings.currentSchema)
    }

    func testUnknownModeFallsBackToOff() throws {
        let defaults = try makeDefaults()
        defaults.set("unknown-mode", forKey: "monitorMode")

        XCTAssertEqual(Settings(defaults).mode, .off)
    }

    func testUnknownEQPresetFallsBackToFlat() throws {
        let defaults = try makeDefaults()
        defaults.set("unknown-preset", forKey: "voice.eq.preset")

        XCTAssertEqual(Settings(defaults).eqPreset, .flat)
    }

    func testUndecodableMixerDataFallsBackToDefaultChannels() throws {
        let defaults = try makeDefaults()
        defaults.set(Data("not JSON".utf8), forKey: "mixer.channels")

        XCTAssertEqual(Settings(defaults).mixerChannels, MixerEngine.defaultChannels)
    }

    func testModeRoundTrips() throws {
        let defaults = try makeDefaults()
        let settings = Settings(defaults)

        for mode: MonitorEngine.Mode in [.always, .auto, .off] {
            settings.mode = mode
            XCTAssertEqual(Settings(defaults).mode, mode)
        }
    }

    func testInputPreferenceAndNameRoundTrip() throws {
        let defaults = try makeDefaults()
        let settings = Settings(defaults)
        settings.inputPreference = .device(uid: "test-microphone-uid")
        settings.inputSourceName = "Test microphone"

        let reloaded = Settings(defaults)
        XCTAssertEqual(reloaded.inputPreference, .device(uid: "test-microphone-uid"))
        XCTAssertEqual(reloaded.inputSourceName, "Test microphone")

        settings.inputPreference = .automatic
        settings.inputSourceName = nil
        XCTAssertEqual(Settings(defaults).inputPreference, .automatic)
        XCTAssertNil(Settings(defaults).inputSourceName)
    }

    func testLevelRoundTrips() throws {
        let defaults = try makeDefaults()
        let settings = Settings(defaults)

        for level: Float in [0, 0.375, 1] {
            settings.level = level
            XCTAssertEqual(Settings(defaults).level, level)
        }

        // Assigning nil leaves an existing level unchanged.
        settings.level = nil
        XCTAssertEqual(Settings(defaults).level, 1)
    }

    func testEQRoundTrips() throws {
        let defaults = try makeDefaults()
        let settings = Settings(defaults)

        for enabled in [true, false] {
            settings.eqEnabled = enabled
            XCTAssertEqual(Settings(defaults).eqEnabled, enabled)
        }
        for preset in EQPreset.builtIns {
            settings.eqPreset = preset
            XCTAssertEqual(Settings(defaults).eqPreset, preset)
        }
    }

    func testNoiseSuppressionRoundTrips() throws {
        let defaults = try makeDefaults()
        let settings = Settings(defaults)

        for mode: MonitorEngine.NoiseSuppression in [.gate, .studio, .off] {
            settings.noiseSuppression = mode
            XCTAssertEqual(Settings(defaults).noiseSuppression, mode)
        }
    }

    func testMixerRoundTrips() throws {
        let defaults = try makeDefaults()
        let settings = Settings(defaults)
        let channels: [MixerEngine.Channel] = [
            .init(source: .voice, name: "Voice", level: 0.5, muted: true),
            .init(source: .desktop, name: "Desktop audio", level: 0.25),
            .init(source: .app(bundleID: "com.example.audio"), name: "Audio app", level: 0.8),
        ]
        settings.mixerChannels = channels

        XCTAssertEqual(Settings(defaults).mixerChannels, channels)
        for enabled in [true, false] {
            settings.mixerEnabled = enabled
            XCTAssertEqual(Settings(defaults).mixerEnabled, enabled)
        }
    }

    func testLightingWithoutColorRoundTrips() throws {
        let defaults = try makeDefaults()
        let settings = Settings(defaults)
        let state = LightingState(effect: .spectrum, brightnessPercent: 65)
        settings.lightingState = state

        XCTAssertEqual(Settings(defaults).lightingState, state)
    }

    func testLightingWithColorRoundTripsAndCanBeCleared() throws {
        let defaults = try makeDefaults()
        let settings = Settings(defaults)
        let state = LightingState(effect: .static, color: RGB(12, 34, 56), brightnessPercent: 40)
        settings.lightingState = state

        XCTAssertEqual(Settings(defaults).lightingState, state)

        settings.lightingState = nil
        XCTAssertNil(Settings(defaults).lightingState)
        XCTAssertNil(defaults.object(forKey: "lighting.effect"))
        XCTAssertNil(defaults.object(forKey: "lighting.color"))
        XCTAssertNil(defaults.object(forKey: "lighting.brightness"))
    }

    func testFutureSchemaLeavesStoredValuesUntouched() throws {
        let defaults = try makeDefaults()
        let stored: [String: Any] = [
            "schemaVersion": Settings.currentSchema + 1,
            "monitoringEnabled": true,
            "input.source": "future-device",
            "input.sourceName": "Future microphone",
            "monitorLevel": 0.625,
            "voice.eq.enabled": true,
            "voice.eq.preset": "Future preset",
            "voice.ns.mode": "future-mode",
            "mixer.enabled": true,
            "mixer.channels": Data("future format".utf8),
            "lighting.effect": 255,
            "lighting.color": "44D62C",
            "lighting.brightness": 73,
            "future.setting": "preserved",
        ]
        for (key, value) in stored { defaults.set(value, forKey: key) }

        for mode in [nil, "future-mode"] as [String?] {
            defaults.set(mode, forKey: "monitorMode")
            let before = defaults.dictionaryRepresentation() as NSDictionary

            _ = Settings(defaults)

            XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
            XCTAssertEqual(defaults.string(forKey: "monitorMode"), mode)
            XCTAssertEqual(defaults.integer(forKey: "schemaVersion"), Settings.currentSchema + 1)
        }
    }
}
