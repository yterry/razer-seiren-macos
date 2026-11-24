import Foundation
import SeirenKit

/// Every string the menu, its dialogs, tooltips and accessibility labels show,
/// resolved through `en.lproj/Localizable.strings` in the app bundle. The value
/// given here is the English text, so an unbundled `swift run` build, which has
/// no strings file, still shows English.
///
/// Left in English on purpose, and not in this table: the diagnostics report,
/// the event log, anything written to stderr, and the strings SeirenKit builds
/// for them.
///
/// `LocalizableStringsTests` checks that `Resources/en.lproj/Localizable.strings`
/// holds every key here with the same value, so keep each value a single string
/// literal.
enum Strings {
    // MARK: - Shared

    static var tryAgain: String {
        NSLocalizedString("common.tryAgain", bundle: .main, value: "Try Again", comment: "Menu item that retries a failed action")
    }
    static var cancel: String {
        NSLocalizedString("common.cancel", bundle: .main, value: "Cancel", comment: "Dialog button")
    }
    static func percent(_ value: Int) -> String {
        String(format: NSLocalizedString("common.percent", bundle: .main, value: "%ld%%", comment: "A level as a percentage, e.g. 42%"), value)
    }

    // MARK: - Crash report

    static var crashNotice: String {
        NSLocalizedString("crash.notice", bundle: .main, value: "Seiren quit unexpectedly last time", comment: "Menu line after a crash")
    }
    static var crashCopy: String {
        NSLocalizedString("crash.copy", bundle: .main, value: "Copy Crash Report", comment: "Menu item")
    }
    static var crashReport: String {
        NSLocalizedString("crash.report", bundle: .main, value: "Report on GitHub…", comment: "Menu item that opens a new bug report")
    }
    static var crashDismiss: String {
        NSLocalizedString("crash.dismiss", bundle: .main, value: "Dismiss", comment: "Menu item that hides the crash notice")
    }
    static func crashReadFailed(_ error: String) -> String {
        String(format: NSLocalizedString("crash.readFailed", bundle: .main, value: "Couldn't read the crash report: %@", comment: "Error dialog; %@ is the system's error text"), error)
    }

    // MARK: - Status line

    static var defaultDeviceName: String {
        NSLocalizedString("status.defaultDevice", bundle: .main, value: "Seiren", comment: "Device name in the status line when no microphone is known")
    }
    static func statusNoSeirenUsing(_ device: String) -> String {
        String(format: NSLocalizedString("status.noSeiren.using", bundle: .main, value: "No Seiren · Seiren FX is using %@", comment: "Status line; %@ is a microphone name"), device)
    }
    static func statusProcessing(_ device: String) -> String {
        String(format: NSLocalizedString("status.processing", bundle: .main, value: "Processing: %@ → Seiren FX", comment: "Status line; %@ is a microphone name"), device)
    }
    static func statusNoSeirenWillUse(_ device: String) -> String {
        String(format: NSLocalizedString("status.noSeiren.willUse", bundle: .main, value: "No Seiren · Seiren FX will use %@", comment: "Status line; %@ is a microphone name"), device)
    }
    static func statusStandby(_ device: String) -> String {
        String(format: NSLocalizedString("status.standby", bundle: .main, value: "Standby: %@ → Seiren FX", comment: "Status line; %@ is a microphone name"), device)
    }
    static func statusMonitoring(_ device: String) -> String {
        String(format: NSLocalizedString("status.monitoring", bundle: .main, value: "Monitoring: %@", comment: "Status line; %@ is a microphone name"), device)
    }
    static var statusAutoWaiting: String {
        NSLocalizedString("status.autoWaiting", bundle: .main, value: "Auto: waiting for an app to use the mic", comment: "Status line")
    }
    static var statusNoMicrophone: String {
        NSLocalizedString("status.noMicrophone", bundle: .main, value: "No microphone detected", comment: "Status line")
    }
    static var statusNoSeiren: String {
        NSLocalizedString("status.noSeiren", bundle: .main, value: "No Seiren detected", comment: "Status line")
    }
    static func statusNeedsFX(_ device: String) -> String {
        String(format: NSLocalizedString("status.needsFX", bundle: .main, value: "%@ needs Seiren FX", comment: "Status line; %@ is a microphone name"), device)
    }
    static var statusPermissionDenied: String {
        NSLocalizedString("status.permissionDenied", bundle: .main, value: "Microphone access denied", comment: "Status line")
    }
    static var statusFailed: String {
        NSLocalizedString("status.failed", bundle: .main, value: "Couldn't start audio", comment: "Status line")
    }
    static func statusReady(_ device: String) -> String {
        String(format: NSLocalizedString("status.ready", bundle: .main, value: "Ready: %@", comment: "Status line; %@ is a microphone name"), device)
    }
    static var statusOff: String {
        NSLocalizedString("status.off", bundle: .main, value: "Monitoring off", comment: "Status line")
    }

    // MARK: - Main menu

    static var fxRouteFailed: String {
        NSLocalizedString("menu.fxRouteFailed", bundle: .main, value: "Seiren FX couldn't start - apps using it hear silence", comment: "Menu line")
    }
    static var waitingForFXRecording: String {
        NSLocalizedString("menu.waitingForFXRecording", bundle: .main, value: "Starts when an app records from Seiren FX", comment: "Menu line")
    }
    static var microphoneAccessRequired: String {
        NSLocalizedString("menu.microphoneAccessRequired", bundle: .main, value: "Microphone access is required", comment: "Menu line")
    }
    static var openMicrophoneSettings: String {
        NSLocalizedString("menu.openMicrophoneSettings", bundle: .main, value: "Open Microphone Settings…", comment: "Menu item")
    }
    static var modeOff: String {
        NSLocalizedString("menu.mode.off", bundle: .main, value: "Off", comment: "Monitoring mode")
    }
    static var modeAlways: String {
        NSLocalizedString("menu.mode.always", bundle: .main, value: "On — always", comment: "Monitoring mode")
    }
    static var modeAuto: String {
        NSLocalizedString("menu.mode.auto", bundle: .main, value: "Auto — only while an app uses the mic", comment: "Monitoring mode")
    }
    static func versionLine(app: String, installedFX: String?) -> String {
        guard let installedFX else {
            return String(format: NSLocalizedString("menu.version.fxNotInstalled", bundle: .main, value: "Seiren %@ · Seiren FX not installed", comment: "Menu line; %@ is the app version"), app)
        }
        return String(format: NSLocalizedString("menu.version", bundle: .main, value: "Seiren %1$@ · Seiren FX %2$@", comment: "Menu line; %1$@ is the app version, %2$@ the driver version"), app, installedFX)
    }
    static func newRelease(_ version: String) -> String {
        String(format: NSLocalizedString("menu.newRelease", bundle: .main, value: "Version %@ is available", comment: "Menu item; %@ is a version number"), version)
    }
    static var copyDiagnostics: String {
        NSLocalizedString("menu.copyDiagnostics", bundle: .main, value: "Copy Diagnostics", comment: "Menu item")
    }
    static var quit: String {
        NSLocalizedString("menu.quit", bundle: .main, value: "Quit Seiren", comment: "Menu item")
    }
    static var errorTitle: String {
        NSLocalizedString("alert.error.title", bundle: .main, value: "Seiren", comment: "Title of an error dialog")
    }

    // MARK: - Volume

    static var volumeCaption: String {
        NSLocalizedString("volume.caption", bundle: .main, value: "Volume", comment: "Caption above the volume slider")
    }
    static var volumeLabel: String {
        NSLocalizedString("volume.label", bundle: .main, value: "Headphone monitor volume", comment: "Accessibility label and tooltip of the volume slider")
    }

    // MARK: - Input

    static var inputTitle: String {
        NSLocalizedString("input.title", bundle: .main, value: "Input", comment: "Submenu title")
    }
    static var inputAutomatic: String {
        NSLocalizedString("input.automatic", bundle: .main, value: "Automatic", comment: "Input choice")
    }
    static var inputAutomaticHint: String {
        NSLocalizedString("input.automaticHint", bundle: .main, value: "Seiren first, then your default mic", comment: "Menu line under Automatic")
    }
    static func inputNotConnected(_ name: String) -> String {
        String(format: NSLocalizedString("input.notConnected", bundle: .main, value: "%@ (not connected)", comment: "Input choice; %@ is a microphone name"), name)
    }
    static var inputNeedsMacOS14: String {
        NSLocalizedString("input.needsMacOS14", bundle: .main, value: "Other mics need macOS 14 or later", comment: "Menu line")
    }
    static var inputNeedsFX: String {
        NSLocalizedString("input.needsFX", bundle: .main, value: "Other mics need Seiren FX (see Voice)", comment: "Menu line")
    }

    // MARK: - Voice

    static var voiceTitle: String {
        NSLocalizedString("voice.title", bundle: .main, value: "Voice", comment: "Submenu title")
    }
    static var voiceRunBuildDriver: String {
        NSLocalizedString("voice.runBuildDriver", bundle: .main, value: "Run scripts/build-driver.sh", comment: "Menu line")
    }
    static var voiceThenInstallDriver: String {
        NSLocalizedString("voice.thenInstallDriver", bundle: .main, value: "then sudo scripts/install-driver.sh", comment: "Menu line")
    }
    static var voiceEnablesEQ: String {
        NSLocalizedString("voice.enablesEQ", bundle: .main, value: "Enables EQ in OBS / Zoom / Discord", comment: "Menu line under the install item")
    }
    static var voiceBuildDriver: String {
        NSLocalizedString("voice.buildDriver", bundle: .main, value: "Build the Seiren FX driver to use EQ", comment: "Menu line")
    }
    static var voiceSeeReadme: String {
        NSLocalizedString("voice.seeReadme", bundle: .main, value: "(see the README — scripts/build-driver.sh)", comment: "Menu line")
    }
    static var voiceEqualizer: String {
        NSLocalizedString("voice.equalizer", bundle: .main, value: "Equalizer", comment: "Menu item that turns the EQ on or off")
    }
    static var voicePreset: String {
        NSLocalizedString("voice.preset", bundle: .main, value: "Preset", comment: "Header above the EQ presets")
    }
    static var voicePresetTurnOnEQ: String {
        NSLocalizedString("voice.presetTurnOnEQ", bundle: .main, value: "Preset (turn on Equalizer)", comment: "Header above the EQ presets while the EQ is off")
    }
    /// A built-in preset's name for display. The stored name stays English.
    static func eqPresetName(_ preset: EQPreset) -> String {
        switch preset.name {
        case EQPreset.flat.name:
            NSLocalizedString("voice.preset.flat", bundle: .main, value: "Flat", comment: "EQ preset")
        case EQPreset.podcast.name:
            NSLocalizedString("voice.preset.podcast", bundle: .main, value: "Podcast", comment: "EQ preset")
        case EQPreset.studio.name:
            NSLocalizedString("voice.preset.studio", bundle: .main, value: "Studio", comment: "EQ preset")
        case EQPreset.broadcast.name:
            NSLocalizedString("voice.preset.broadcast", bundle: .main, value: "Broadcast", comment: "EQ preset")
        default:
            preset.name
        }
    }
    static var voiceNoiseSuppression: String {
        NSLocalizedString("voice.noiseSuppression", bundle: .main, value: "Noise suppression", comment: "Header above the noise suppression choices")
    }
    static var voiceNoiseSuppressionOff: String {
        NSLocalizedString("voice.noiseSuppression.off", bundle: .main, value: "Off", comment: "Noise suppression choice")
    }
    static var voiceNoiseSuppressionGate: String {
        NSLocalizedString("voice.noiseSuppression.gate", bundle: .main, value: "Reduce noise (gate)", comment: "Noise suppression choice")
    }
    static var voiceNoiseSuppressionStudio: String {
        NSLocalizedString("voice.noiseSuppression.studio", bundle: .main, value: "Studio Denoise (RNNoise)", comment: "Noise suppression choice")
    }
    static var voiceStudioWithMonitor: String {
        NSLocalizedString("voice.studio.withMonitor", bundle: .main, value: "Studio: removes steady noise · your monitor stays low-latency", comment: "Menu line")
    }
    static var voiceStudioWithoutMonitor: String {
        NSLocalizedString("voice.studio.withoutMonitor", bundle: .main, value: "Studio: removes steady noise · adds ~10 ms to Seiren FX", comment: "Menu line")
    }
    static var voiceCaptionHeardInMonitor: String {
        NSLocalizedString("voice.caption.heardInMonitor", bundle: .main, value: "Heard in your monitor + apps recording “Seiren FX”", comment: "Where the EQ is heard")
    }
    static var voiceCaptionHeardByApps: String {
        NSLocalizedString("voice.caption.heardByApps", bundle: .main, value: "Heard by apps recording “Seiren FX”", comment: "Where the EQ is heard")
    }
    static var voiceCaptionFXFailed: String {
        NSLocalizedString("voice.caption.fxFailed", bundle: .main, value: "Seiren FX couldn't start - the EQ isn't applied", comment: "Where the EQ is heard")
    }
    static var voiceCaptionTurnOnMonitoring: String {
        NSLocalizedString("voice.caption.turnOnMonitoring", bundle: .main, value: "Turn monitoring on to apply the EQ", comment: "Where the EQ is heard")
    }
    static var voiceCaptionAppliesWhenActive: String {
        NSLocalizedString("voice.caption.appliesWhenActive", bundle: .main, value: "Applies once monitoring is active", comment: "Where the EQ is heard")
    }

    // MARK: - Stream Mixer

    static var mixerTitle: String {
        NSLocalizedString("mixer.title", bundle: .main, value: "Stream Mixer", comment: "Submenu title")
    }
    static var mixerAddsStreamMix: String {
        NSLocalizedString("mixer.addsStreamMix", bundle: .main, value: "Adds the Seiren Stream Mix device", comment: "Menu line under the update item")
    }
    static var mixerAddsFXAndStreamMix: String {
        NSLocalizedString("mixer.addsFXAndStreamMix", bundle: .main, value: "Adds Seiren FX and Seiren Stream Mix", comment: "Menu line under the install item")
    }
    static var mixerRebuildDriver: String {
        NSLocalizedString("mixer.rebuildDriver", bundle: .main, value: "Rebuild the driver: scripts/build-driver.sh", comment: "Menu line")
    }
    static var mixerThenInstallDriver: String {
        NSLocalizedString("mixer.thenInstallDriver", bundle: .main, value: "then: sudo scripts/install-driver.sh", comment: "Menu line")
    }
    static var mixerNeedsMacOS: String {
        NSLocalizedString("mixer.needsMacOS", bundle: .main, value: "Needs macOS 14.2 or later", comment: "Menu line")
    }
    static var mixerToggle: String {
        NSLocalizedString("mixer.toggle", bundle: .main, value: "Mix into Seiren Stream Mix", comment: "Menu item that turns the mixer on or off")
    }
    static var mixerOBSHint: String {
        NSLocalizedString("mixer.obsHint", bundle: .main, value: "In OBS, pick “Seiren Stream Mix” as the mic", comment: "Menu line")
    }
    static var mixerDesktopTooltip: String {
        NSLocalizedString("mixer.desktopTooltip", bundle: .main, value: "Every app without its own channel", comment: "Tooltip of the Desktop audio channel")
    }
    static var mixerAddApp: String {
        NSLocalizedString("mixer.addApp", bundle: .main, value: "Add App", comment: "Submenu title")
    }
    static var mixerRemoveApp: String {
        NSLocalizedString("mixer.removeApp", bundle: .main, value: "Remove App", comment: "Submenu title")
    }
    static var mixerAppLimit: String {
        NSLocalizedString("mixer.appLimit", bundle: .main, value: "Up to 6 apps", comment: "Menu line when no more apps can be added")
    }
    static var mixerNoOtherApps: String {
        NSLocalizedString("mixer.noOtherApps", bundle: .main, value: "No other apps are open", comment: "Menu line")
    }
    static var mixerLive: String {
        NSLocalizedString("mixer.state.live", bundle: .main, value: "Live · mixing into Seiren Stream Mix", comment: "Mixer state")
    }
    static var mixerFailed: String {
        NSLocalizedString("mixer.state.failed", bundle: .main, value: "Couldn't start the Stream Mixer", comment: "Mixer state")
    }
    static var mixerWaiting: String {
        NSLocalizedString("mixer.state.waiting", bundle: .main, value: "Starts when an app records Seiren Stream Mix", comment: "Mixer state")
    }
    static var mixerVoiceSilent: String {
        NSLocalizedString("mixer.voiceSilent", bundle: .main, value: "Voice is silent while monitoring is Off", comment: "Menu line")
    }
    /// A channel's name for display. The built-in channels' stored names stay English.
    static func mixerChannelName(_ channel: MixerEngine.Channel) -> String {
        switch channel.source {
        case .voice:
            NSLocalizedString("mixer.channel.voice", bundle: .main, value: "Voice", comment: "Stream Mixer channel")
        case .desktop:
            NSLocalizedString("mixer.channel.desktop", bundle: .main, value: "Desktop audio", comment: "Stream Mixer channel")
        case .app:
            channel.name
        }
    }
    static var mixerMuted: String {
        NSLocalizedString("mixer.row.muted", bundle: .main, value: "Muted", comment: "Value of a muted channel")
    }
    static var mixerUnmuted: String {
        NSLocalizedString("mixer.row.unmuted", bundle: .main, value: "Unmuted", comment: "Accessibility value of a channel's mute button")
    }
    static var mixerMute: String {
        NSLocalizedString("mixer.row.mute", bundle: .main, value: "Mute on stream", comment: "Tooltip of a channel's mute button")
    }
    static var mixerUnmute: String {
        NSLocalizedString("mixer.row.unmute", bundle: .main, value: "Unmute on stream", comment: "Tooltip of a channel's mute button")
    }
    static func mixerLevelLabel(_ channel: String) -> String {
        String(format: NSLocalizedString("mixer.row.levelLabel", bundle: .main, value: "%@ level on stream", comment: "Accessibility label of a channel's slider; %@ is the channel name"), channel)
    }
    static func mixerMuteLabel(_ channel: String, _ action: String) -> String {
        String(format: NSLocalizedString("mixer.row.muteLabel", bundle: .main, value: "%1$@: %2$@", comment: "Accessibility label of a channel's mute button; %1$@ is the channel name, %2$@ its tooltip"), channel, action)
    }

    // MARK: - Lighting

    static var lightingTitle: String {
        NSLocalizedString("lighting.title", bundle: .main, value: "Lighting", comment: "Submenu title")
    }
    static var lightingNeedsInputMonitoring: String {
        NSLocalizedString("lighting.needsInputMonitoring", bundle: .main, value: "Lighting needs Input Monitoring access", comment: "Menu line")
    }
    static var lightingOpenInputMonitoringSettings: String {
        NSLocalizedString("lighting.openInputMonitoringSettings", bundle: .main, value: "Open Input Monitoring Settings…", comment: "Menu item")
    }
    static var lightingAppliesWhenConnected: String {
        NSLocalizedString("lighting.appliesWhenConnected", bundle: .main, value: "Applies when the Seiren is connected", comment: "Menu line")
    }
    static var lightingSpectrum: String {
        NSLocalizedString("lighting.effect.spectrum", bundle: .main, value: "Spectrum (device default)", comment: "Lighting effect")
    }
    static var lightingBreathing: String {
        NSLocalizedString("lighting.effect.breathing", bundle: .main, value: "Breathing", comment: "Lighting effect")
    }
    static var lightingWave: String {
        NSLocalizedString("lighting.effect.wave", bundle: .main, value: "Wave", comment: "Lighting effect")
    }
    static var lightingStatic: String {
        NSLocalizedString("lighting.effect.static", bundle: .main, value: "Static", comment: "Lighting effect with one color")
    }
    static var lightingOff: String {
        NSLocalizedString("lighting.effect.off", bundle: .main, value: "Off", comment: "Lighting effect")
    }
    static var lightingRazerGreen: String {
        NSLocalizedString("lighting.color.razerGreen", bundle: .main, value: "Razer Green", comment: "Lighting color")
    }
    static var lightingWhite: String {
        NSLocalizedString("lighting.color.white", bundle: .main, value: "White", comment: "Lighting color")
    }
    static var lightingRed: String {
        NSLocalizedString("lighting.color.red", bundle: .main, value: "Red", comment: "Lighting color")
    }
    static var lightingOrange: String {
        NSLocalizedString("lighting.color.orange", bundle: .main, value: "Orange", comment: "Lighting color")
    }
    static var lightingYellow: String {
        NSLocalizedString("lighting.color.yellow", bundle: .main, value: "Yellow", comment: "Lighting color")
    }
    static var lightingCyan: String {
        NSLocalizedString("lighting.color.cyan", bundle: .main, value: "Cyan", comment: "Lighting color")
    }
    static var lightingBlue: String {
        NSLocalizedString("lighting.color.blue", bundle: .main, value: "Blue", comment: "Lighting color")
    }
    static var lightingPurple: String {
        NSLocalizedString("lighting.color.purple", bundle: .main, value: "Purple", comment: "Lighting color")
    }
    static var lightingPink: String {
        NSLocalizedString("lighting.color.pink", bundle: .main, value: "Pink", comment: "Lighting color")
    }
    static var lightingUnreachable: String {
        NSLocalizedString("lighting.unreachable", bundle: .main, value: "Couldn't reach the mic's lighting", comment: "Menu line")
    }
    static var lightingBrightnessCaption: String {
        NSLocalizedString("lighting.brightness.caption", bundle: .main, value: "Brightness", comment: "Caption above the brightness slider")
    }
    static var lightingBrightnessLabel: String {
        NSLocalizedString("lighting.brightness.label", bundle: .main, value: "Lighting brightness", comment: "Accessibility label and tooltip of the brightness slider")
    }

    // MARK: - Launch at Login

    static var launchAtLogin: String {
        NSLocalizedString("login.title", bundle: .main, value: "Launch at Login", comment: "Menu item")
    }
    static var launchAtLoginPackagedOnly: String {
        NSLocalizedString("login.packagedOnly", bundle: .main, value: "Launch at Login (packaged app only)", comment: "Menu item in a build without an app bundle")
    }
    static var launchAtLoginNeedsApproval: String {
        NSLocalizedString("login.needsApproval", bundle: .main, value: "Launch at Login (needs approval)", comment: "Menu item")
    }
    static func launchAtLoginTurnOnFailed(_ error: String) -> String {
        String(format: NSLocalizedString("login.turnOnFailed", bundle: .main, value: "Couldn't turn on Launch at Login: %@", comment: "Error dialog; %@ is the system's error text"), error)
    }
    static func launchAtLoginTurnOffFailed(_ error: String) -> String {
        String(format: NSLocalizedString("login.turnOffFailed", bundle: .main, value: "Couldn't turn off Launch at Login: %@", comment: "Error dialog; %@ is the system's error text"), error)
    }

    // MARK: - First launch

    static var welcomeTitle: String {
        NSLocalizedString("welcome.title", bundle: .main, value: "Seiren runs in the menu bar", comment: "First launch dialog")
    }
    static var welcomeMessage: String {
        NSLocalizedString("welcome.message", bundle: .main, value: "Seiren has no window and no Dock icon. Click the microphone icon in the menu bar to change its settings.\n\nAuto is the recommended mode. It runs headphone monitoring and voice processing only while another app is using the microphone, such as during a call. macOS asks for microphone access the first time a mode is turned on.", comment: "First launch dialog")
    }
    static var welcomeTurnOnAuto: String {
        NSLocalizedString("welcome.turnOnAuto", bundle: .main, value: "Turn on Auto", comment: "First launch dialog button")
    }
    static var welcomeNotNow: String {
        NSLocalizedString("welcome.notNow", bundle: .main, value: "Not now", comment: "First launch dialog button")
    }

    // MARK: - Seiren FX driver

    static var driverNoHeadphoneJack: String {
        NSLocalizedString("driver.noHeadphoneJack", bundle: .main, value: "This mic has no headphone jack - it works through Seiren FX", comment: "Menu line")
    }
    static var driverInstallFirst: String {
        NSLocalizedString("driver.installFirst", bundle: .main, value: "Install Seiren FX first (scripts/install-driver.sh)", comment: "Menu line")
    }
    static var driverNeedsReinstall: String {
        NSLocalizedString("driver.needsReinstall", bundle: .main, value: "Seiren FX needs a one-time reinstall", comment: "Menu line")
    }
    static var driverUpdateAvailable: String {
        NSLocalizedString("driver.updateAvailable", bundle: .main, value: "A newer Seiren FX comes with this app", comment: "Menu line")
    }
    static var driverVerbInstall: String {
        NSLocalizedString("driver.verb.install", bundle: .main, value: "Install", comment: "Driver action, used in the menu item, dialog title and button")
    }
    static var driverVerbUpdate: String {
        NSLocalizedString("driver.verb.update", bundle: .main, value: "Update", comment: "Driver action, used in the menu item, dialog title and button")
    }
    static var driverVerbReinstall: String {
        NSLocalizedString("driver.verb.reinstall", bundle: .main, value: "Reinstall", comment: "Driver action, used in the menu item, dialog title and button")
    }
    static var driverVerbUninstall: String {
        NSLocalizedString("driver.verb.uninstall", bundle: .main, value: "Uninstall", comment: "Driver action, used in the menu item, dialog title and button")
    }
    static func driverMenuItem(_ verb: String) -> String {
        String(format: NSLocalizedString("driver.menuItem", bundle: .main, value: "%@ Seiren FX…", comment: "Menu item; %@ is a driver action such as Install"), verb)
    }
    static func driverConfirmTitle(_ verb: String) -> String {
        String(format: NSLocalizedString("driver.confirm.title", bundle: .main, value: "%@ Seiren FX?", comment: "Dialog title; %@ is a driver action such as Install"), verb)
    }
    static var driverConfirmInstalling: String {
        NSLocalizedString("driver.confirm.installing", bundle: .main, value: "Installing Seiren FX restarts audio on this Mac for about a second. Calls and recordings in other apps will be interrupted.", comment: "Dialog text before an install, update or reinstall")
    }
    static var driverConfirmUninstalling: String {
        NSLocalizedString("driver.confirm.uninstalling", bundle: .main, value: "Uninstalling Seiren FX restarts audio on this Mac for about a second. Calls and recordings in other apps will be interrupted.", comment: "Dialog text before an uninstall")
    }
    static var driverInstalledTitle: String {
        NSLocalizedString("driver.installed.title", bundle: .main, value: "Seiren FX installed", comment: "Dialog title")
    }
    static var driverInstalledMessage: String {
        NSLocalizedString("driver.installed.message", bundle: .main, value: "Audio was restarted. Turn on the Equalizer under Voice, then choose “Seiren FX” as the microphone in OBS / Zoom / Discord to send them your processed voice.", comment: "Dialog text after a first install")
    }
    static var driverUpdatedTitle: String {
        NSLocalizedString("driver.updated.title", bundle: .main, value: "Seiren FX updated", comment: "Dialog title")
    }
    static var driverReinstalledTitle: String {
        NSLocalizedString("driver.reinstalled.title", bundle: .main, value: "Seiren FX reinstalled", comment: "Dialog title")
    }
    static var driverReplacedMessage: String {
        NSLocalizedString("driver.replaced.message", bundle: .main, value: "Audio was restarted. Your Voice settings and the apps that use Seiren FX keep working as before.", comment: "Dialog text after an update or reinstall")
    }
    static var driverNotLoadedTitle: String {
        NSLocalizedString("driver.notLoaded.title", bundle: .main, value: "Seiren FX was copied but macOS did not load it", comment: "Dialog title")
    }
    static func driverNotLoadedMessage(_ path: String) -> String {
        String(format: NSLocalizedString("driver.notLoaded.message", bundle: .main, value: "The driver is at:\n%@\n\nRestart the Mac to load it.", comment: "Dialog text; %@ is the driver's path"), path)
    }
    static func driverInstallFailed(_ reason: String) -> String {
        String(format: NSLocalizedString("driver.installFailed", bundle: .main, value: "Couldn't install Seiren FX:\n%@\n\nYou can also install it manually with scripts/install-driver.sh.", comment: "Error dialog; %@ is why the install failed"), reason)
    }
    static func driverUninstallFailed(_ reason: String) -> String {
        String(format: NSLocalizedString("driver.uninstallFailed", bundle: .main, value: "Couldn't uninstall Seiren FX:\n%@", comment: "Error dialog; %@ is why the uninstall failed"), reason)
    }
    static var driverNotBundled: String {
        NSLocalizedString("driver.notBundled", bundle: .main, value: "The bundled SeirenFX.driver wasn't found in the app.", comment: "Why an install failed")
    }
    static var driverInvalidAppSignature: String {
        NSLocalizedString("driver.invalidAppSignature", bundle: .main, value: "The Seiren app's signature couldn't be verified. Download a fresh copy of Seiren and try again.", comment: "Why a driver install was refused")
    }
    static var driverInvalidSignature: String {
        NSLocalizedString("driver.invalidSignature", bundle: .main, value: "The bundled Seiren FX driver's signature could not be verified for this copy of Seiren. Download a fresh copy of Seiren and try again.", comment: "Why a driver install was refused")
    }
    static func driverExitStatus(_ status: Int32) -> String {
        String(format: NSLocalizedString("driver.exitStatus", bundle: .main, value: "Installation failed (exit %d).", comment: "Why an install failed; %d is the exit status"), status)
    }
}
