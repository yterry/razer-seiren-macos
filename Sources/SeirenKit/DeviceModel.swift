import Foundation

/// One HID report to send to the device.
///
/// `hex` is the report **payload** — the bytes that follow the report ID. The
/// report ID is sent separately (it is `IOHIDDeviceSetReport`'s `reportID`
/// argument), so do **not** include it in `hex`.
public struct CommandFrame: Codable, Equatable, Sendable {
    public var reportID: UInt8
    public var type: ReportType
    public var hex: String

    public var bytes: [UInt8] { Hex.parse(hex) }

    public init(reportID: UInt8, type: ReportType, hex: String) {
        self.reportID = reportID
        self.type = type
        self.hex = hex
    }
}

public enum ReportType: String, Codable, Equatable, Sendable {
    case feature   // SET_REPORT (Feature) — the V3 Pro's 0xFF53 channel
    case output    // interrupt OUT / Output report
}

/// What we know how to make a given device do. Each entry is `nil` until
/// someone captures it (see CONTRIBUTING.md) — the app is honest about gaps
/// rather than guessing bytes.
public struct CommandTable: Codable, Equatable, Sendable {
    public var monitorOn: CommandFrame?
    public var monitorOff: CommandFrame?
    /// Optional prefix sent before each command (e.g. Razer `setRemoteMode`).
    public var handshake: [CommandFrame]?

    public init(monitorOn: CommandFrame? = nil,
                monitorOff: CommandFrame? = nil,
                handshake: [CommandFrame]? = nil) {
        self.monitorOn = monitorOn
        self.monitorOff = monitorOff
        self.handshake = handshake
    }
}

/// A known Razer Seiren model and how to talk to it.
public struct DeviceModel: Codable, Equatable, Sendable {
    public var name: String
    /// USB product ID (VID is always Razer = 0x1532).
    public var pid: UInt16
    /// Informational: the vendor HID usage page the Razer control report rides
    /// (0xFF53 on the V3 Pro, 0xFF07 on the V3 Mini).
    public var hidUsagePage: UInt16
    /// True when the model has a Chroma RGB zone driven by the Razer "Device25"
    /// lighting protocol (docs/PROTOCOL.md §5) - the V3 Pro's 12-LED ring.
    /// Models without one (the V3 Mini has only a red/green mute LED) are
    /// never opened or written to by the lighting code, so a command class we
    /// verified on one firmware can't be aimed at another we haven't.
    /// Absent in JSON = false: lighting is opted into per model, never assumed.
    public var chromaLighting: Bool
    public var commands: CommandTable
    public var notes: String?

    public init(name: String, pid: UInt16, hidUsagePage: UInt16,
                chromaLighting: Bool = false,
                commands: CommandTable = CommandTable(), notes: String? = nil) {
        self.name = name
        self.pid = pid
        self.hidUsagePage = hidUsagePage
        self.chromaLighting = chromaLighting
        self.commands = commands
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case name, pid, hidUsagePage, chromaLighting, commands, notes
    }

    /// Hand-written so optional capability keys can be omitted from a
    /// contributed `devices/*.json` (the synthesized decoder would demand them).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        pid = try c.decode(UInt16.self, forKey: .pid)
        hidUsagePage = try c.decode(UInt16.self, forKey: .hidUsagePage)
        chromaLighting = try c.decodeIfPresent(Bool.self, forKey: .chromaLighting) ?? false
        commands = try c.decodeIfPresent(CommandTable.self, forKey: .commands) ?? CommandTable()
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }

    /// True once the monitor-on bytes have been captured for this model.
    public var monitorSupported: Bool { commands.monitorOn != nil }
}
