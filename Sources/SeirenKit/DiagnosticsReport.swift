import CoreAudio
import Foundation

/// Everything "Copy Diagnostics" reports, captured on the main thread so
/// `DiagnosticsReport.render` can be a pure function with unit tests.
public struct DiagnosticsSnapshot {
    public struct Versions {
        public var app: String
        public var macOS: String
        public var architecture: String
        public var installedFX: String?
        public var bundledFX: String?
        public var reinstallOffered: Bool
        public var updateOffered: Bool

        public init(app: String, macOS: String, architecture: String, installedFX: String?,
                    bundledFX: String?, reinstallOffered: Bool, updateOffered: Bool) {
            self.app = app
            self.macOS = macOS
            self.architecture = architecture
            self.installedFX = installedFX
            self.bundledFX = bundledFX
            self.reinstallOffered = reinstallOffered
            self.updateOffered = updateOffered
        }
    }

    public struct Engine {
        public var mode: MonitorEngine.Mode
        public var state: MonitorEngine.State
        public var inputPreference: MonitorEngine.InputPreference
        public var activeSource: MonitorEngine.InputDevice?
        public var routesThroughFX: Bool
        public var standbyRunning: Bool
        public var route: MonitorEngine.RouteDiagnostics
        public var recordingBundleIDs: [String]

        public init(mode: MonitorEngine.Mode, state: MonitorEngine.State,
                    inputPreference: MonitorEngine.InputPreference, activeSource: MonitorEngine.InputDevice?,
                    routesThroughFX: Bool, standbyRunning: Bool, route: MonitorEngine.RouteDiagnostics,
                    recordingBundleIDs: [String]) {
            self.mode = mode
            self.state = state
            self.inputPreference = inputPreference
            self.activeSource = activeSource
            self.routesThroughFX = routesThroughFX
            self.standbyRunning = standbyRunning
            self.route = route
            self.recordingBundleIDs = recordingBundleIDs
        }
    }

    public struct Device {
        public var uid: String
        public var name: String
        public var transport: UInt32?
        public var inputStreams: Int
        public var outputStreams: Int
        public var sampleRate: Double

        public init(uid: String, name: String, transport: UInt32?, inputStreams: Int,
                    outputStreams: Int, sampleRate: Double) {
            self.uid = uid
            self.name = name
            self.transport = transport
            self.inputStreams = inputStreams
            self.outputStreams = outputStreams
            self.sampleRate = sampleRate
        }
    }

    public struct Mixer {
        public var enabled: Bool
        public var availability: MixerEngine.State
        public var state: MixerEngine.State
        public var channelCount: Int
        public var diagnostics: MixerEngine.Diagnostics

        public init(enabled: Bool, availability: MixerEngine.State, state: MixerEngine.State,
                    channelCount: Int, diagnostics: MixerEngine.Diagnostics) {
            self.enabled = enabled
            self.availability = availability
            self.state = state
            self.channelCount = channelCount
            self.diagnostics = diagnostics
        }
    }

    public struct Lighting {
        public var attachedModel: String?
        public var deviceConnected: Bool
        public var lastError: LightingError?

        public init(attachedModel: String?, deviceConnected: Bool, lastError: LightingError?) {
            self.attachedModel = attachedModel
            self.deviceConnected = deviceConnected
            self.lastError = lastError
        }
    }

    public var versions: Versions
    public var engine: Engine
    public var devices: [Device]
    public var mixer: Mixer
    public var lighting: Lighting
    public var microphoneAccess: String
    public var inputMonitoringAccess: String
    /// Recent event log entries, oldest first.
    public var history: [String]

    public init(versions: Versions, engine: Engine, devices: [Device], mixer: Mixer, lighting: Lighting,
                microphoneAccess: String, inputMonitoringAccess: String, history: [String]) {
        self.versions = versions
        self.engine = engine
        self.devices = devices
        self.mixer = mixer
        self.lighting = lighting
        self.microphoneAccess = microphoneAccess
        self.inputMonitoringAccess = inputMonitoringAccess
        self.history = history
    }
}

/// The plain-text report behind the menu's "Copy Diagnostics". Devices other
/// than Seirens and the app's own are listed by transport, never by name, and
/// no device UID is printed, so the text carries no person's name or serial.
public enum DiagnosticsReport {
    public static let historyLimit = 100

    /// The menu's version line.
    public static func versionLine(app: String, installedFX: String?) -> String {
        "Seiren \(app) · " + (installedFX.map { "Seiren FX \($0)" } ?? "Seiren FX not installed")
    }

    public static func render(_ snapshot: DiagnosticsSnapshot) -> String {
        let labels = deviceLabels(snapshot.devices)
        func label(uid: String) -> String? {
            snapshot.devices.firstIndex { $0.uid == uid }.map { labels[$0] }
        }
        var lines = ["Seiren diagnostics - review before posting", ""]

        let v = snapshot.versions
        lines += ["Versions",
                  "  App: \(v.app)",
                  "  macOS: \(v.macOS)",
                  "  CPU: \(v.architecture)",
                  "  Seiren FX installed: \(v.installedFX ?? "no")",
                  "  Seiren FX bundled: \(v.bundledFX ?? "no")",
                  "  Reinstall offered: \(yesNo(v.reinstallOffered))",
                  "  Update offered: \(yesNo(v.updateOffered))",
                  ""]

        let e = snapshot.engine
        let preference: String
        switch e.inputPreference {
        case .automatic: preference = "Automatic"
        case .device(let uid): preference = "Pinned: \(label(uid: uid) ?? "a device that is not connected")"
        }
        let source = e.activeSource.map { label(uid: $0.uid) ?? ($0.isSeiren ? $0.name : "an unlisted input") }
        let r = e.route
        lines += ["Engine",
                  "  Mode: \(e.mode.rawValue)",
                  "  State: \(e.state)",
                  "  Input preference: \(preference)",
                  "  Active source: \(source ?? "none")",
                  "  Through Seiren FX: \(yesNo(e.routesThroughFX))",
                  "  Standby running: \(yesNo(e.standbyRunning))",
                  "  Recording apps: \(e.recordingBundleIDs.isEmpty ? "none" : e.recordingBundleIDs.joined(separator: ", "))",
                  "  Route: \(r.callbacks) callbacks, \(r.inputBuffers) in / \(r.outputBuffers) out buffers, " +
                      "\(r.monitorBuffers) source outputs, \(Int(r.sampleRate)) Hz, mic peak \(dBFS(r.inputPeak))",
                  ""]

        lines.append("Devices")
        if snapshot.devices.isEmpty { lines.append("  none") }
        for (device, name) in zip(snapshot.devices, labels) {
            var row = "  \(name): \(transportName(device.transport)), \(device.inputStreams) in / " +
                "\(device.outputStreams) out streams, \(Int(device.sampleRate)) Hz"
            if let role = role(of: device) { row += ", \(role)" }
            lines.append(row)
        }
        lines.append("")

        let m = snapshot.mixer
        lines += ["Mixer",
                  "  Enabled: \(yesNo(m.enabled))",
                  "  Availability: \(m.availability)",
                  "  State: \(m.state)",
                  "  Channels: \(m.channelCount)"]
        if m.state == .running {
            let d = m.diagnostics
            let map = d.indexMap
            lines += ["  Callbacks: \(d.callbacks), \(d.inputBuffers) in / \(d.outputBuffers) out buffers, " +
                          "\(Int(d.sampleRate)) Hz",
                      "  Index map: inputs \(map.inputChannels.sorted { $0.key < $1.key }.map { "\($0.key)->\($0.value)" }), " +
                          "ignored \(map.ignoredInputs), mix output \(map.mixOutput), silenced \(map.silencedOutputs)",
                      "  Input peaks: \(d.inputPeaks.map(dBFS).joined(separator: ", "))",
                      "  Channel peaks: \(d.channelPeaks.map(dBFS).joined(separator: ", "))",
                      "  Mix output peak: \(dBFS(d.mixOutputPeak))",
                      "  Taps: \(d.taps.map { "\($0.channelName) (\($0.processCount) processes)" }.joined(separator: ", "))"]
        }
        lines.append("")

        let l = snapshot.lighting
        lines += ["Lighting",
                  "  Attached model: \(l.attachedModel ?? "none")",
                  "  Chroma device connected: \(yesNo(l.deviceConnected))",
                  "  Last error: \(l.lastError.map { "\($0)" } ?? "none")",
                  "",
                  "Permissions",
                  "  Microphone: \(snapshot.microphoneAccess)",
                  "  Input Monitoring: \(snapshot.inputMonitoringAccess)",
                  "",
                  "History"]
        if snapshot.history.isEmpty {
            lines.append("  No event history recorded (needs #24)")
        } else {
            lines += snapshot.history.suffix(historyLimit).map { "  \($0)" }
        }

        return scrubHomePaths(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Privacy

    private static let ownDeviceRoles: [String: String] = [
        MonitorEngine.fxDeviceUID: "Seiren FX",
        MonitorEngine.streamMixDeviceUID: "Seiren Stream Mix",
        MonitorEngine.fxFeederUID: "Seiren FX feeder",
        MonitorEngine.streamMixFeederUID: "Seiren Stream Mix feeder",
        MonitorEngine.aggregateUID: "Seiren route aggregate",
        MixerEngine.aggregateUID: "Seiren mixer aggregate",
    ]

    private static func role(of device: DiagnosticsSnapshot.Device) -> String? {
        ownDeviceRoles[device.uid] ?? (isSeiren(device) ? "Seiren" : nil)
    }

    private static func isSeiren(_ device: DiagnosticsSnapshot.Device) -> Bool {
        ownDeviceRoles[device.uid] == nil && device.name.localizedCaseInsensitiveContains("seiren")
    }

    /// Seirens and the app's own devices keep their names; every other device
    /// becomes a transport label such as "Built-in input" or "USB input 1".
    private static func deviceLabels(_ devices: [DiagnosticsSnapshot.Device]) -> [String] {
        var counts: [String: Int] = [:]
        return devices.map { device in
            if ownDeviceRoles[device.uid] != nil || isSeiren(device) { return device.name }
            let direction = device.inputStreams > 0
                ? (device.outputStreams > 0 ? "input and output" : "input") : "output"
            let base = "\(transportName(device.transport)) \(direction)"
            let n = counts[base, default: 0] + 1
            counts[base] = n
            return device.transport == kAudioDeviceTransportTypeBuiltIn && n == 1 ? base : "\(base) \(n)"
        }
    }

    private static func transportName(_ transport: UInt32?) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypePCI: return "PCI"
        case kAudioDeviceTransportTypeFireWire: return "FireWire"
        case kAudioDeviceTransportTypeAVB: return "AVB"
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless: return "Continuity"
        default: return "Other"
        }
    }

    /// Any `/Users/<name>` prefix becomes `~`, so no home-directory path or
    /// account name leaks through free text such as history entries.
    private static func scrubHomePaths(_ text: String) -> String {
        text.replacingOccurrences(of: #"/Users/[^/\s]+"#, with: "~", options: .regularExpression)
    }

    // MARK: - Formatting

    private static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

    private static func dBFS(_ linear: Float) -> String {
        linear > 0 ? String(format: "%.1f dBFS", 20 * log10(linear)) : "silent"
    }
}
