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
    /// Informational: the vendor HID usage page the audio commands ride
    /// (0xFF53 = Razer audio, on the V3 Pro).
    public var hidUsagePage: UInt16
    public var commands: CommandTable
    public var notes: String?

    public init(name: String, pid: UInt16, hidUsagePage: UInt16,
                commands: CommandTable, notes: String? = nil) {
        self.name = name
        self.pid = pid
        self.hidUsagePage = hidUsagePage
        self.commands = commands
        self.notes = notes
    }

    /// True once the monitor-on bytes have been captured for this model.
    public var monitorSupported: Bool { commands.monitorOn != nil }
}
