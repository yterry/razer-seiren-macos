import Foundation

/// The Razer "Device25" command report the Seiren V3 Pro speaks on its vendor
/// HID channel (interface 3, Feature report 0x07), and the Chroma lighting
/// commands that ride it.
///
/// Provenance - none of these bytes are guessed:
///  - Synapse 4's middleware log (`products_1422_mw*.log`) records the full
///    65-byte `dataSend` buffer for every audio command it issues; the layout
///    and checksum below reproduce those captures byte-for-byte (see
///    `RazerLightingTests`).
///  - The Chroma command headers and argument layouts come from Synapse 4's own
///    lighting-engine JavaScript (`rzDevice25AudioCamyT3V2`, v0.0.340), which
///    is publicly served from apps.razer.com. See docs/PROTOCOL.md §6.
///
/// The wire format is the classic Razer control report (the same family
/// openrazer documents for keyboards/mice), sized to 64 bytes:
///
/// ```
/// offset  0     status            0x00 on send; 0x02 = success in replies
///         1     transaction id    echoed in the reply
///         2-3   remaining packets 0
///         4     protocol type     0
///         5     data size         number of meaningful argument bytes
///         6     command class     0x00 device, 0x08 audio, 0x0F Chroma
///         7     command id        get = set | 0x80
///         8-61  arguments         54 bytes, zero-padded
///         62    crc               XOR of bytes 0...61
///         63    reserved          0
/// ```
///
/// The 64-byte body is sent/received as HID **Feature report 0x07** (the report
/// ID travels in the transfer's setup, not in this buffer).
public struct RazerReport: Equatable, Sendable {
    public static let bodyLength = 64
    public static let maxArgs = 54

    public var status: UInt8
    public var transactionId: UInt8
    public var dataSize: UInt8
    public var commandClass: UInt8
    public var commandId: UInt8
    /// Argument bytes (up to `maxArgs`); shorter arrays are zero-padded.
    public var args: [UInt8]

    public init(transactionId: UInt8,
                dataSize: UInt8,
                commandClass: UInt8,
                commandId: UInt8,
                args: [UInt8],
                status: UInt8 = 0) {
        precondition(args.count <= Self.maxArgs, "args exceed report capacity")
        self.status = status
        self.transactionId = transactionId
        self.dataSize = dataSize
        self.commandClass = commandClass
        self.commandId = commandId
        self.args = args
    }

    /// The 64-byte report body with the checksum filled in.
    public func encoded() -> [UInt8] {
        var b = [UInt8](repeating: 0, count: Self.bodyLength)
        b[0] = status
        b[1] = transactionId
        // b[2...4]: remaining packets + protocol type, always 0.
        b[5] = dataSize
        b[6] = commandClass
        b[7] = commandId
        for (i, v) in args.enumerated() { b[8 + i] = v }
        b[Self.bodyLength - 2] = Self.checksum(of: b)
        return b
    }

    /// XOR of bytes 0...61 - matches Synapse's `_calculateChecksum` (which runs
    /// over `reportLength - 3` bytes of the 64-byte body). Note this *includes*
    /// the transaction id, unlike openrazer's 90-byte report where the XOR
    /// starts after it.
    public static func checksum(of body: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0
        for i in 0..<(bodyLength - 2) { crc ^= body[i] }
        return crc
    }

    /// Reply status codes (same family openrazer documents).
    public enum ReplyStatus: UInt8, Sendable {
        case newCommand = 0x00
        case busy = 0x01
        case success = 0x02
        case failure = 0x03
        case timeout = 0x04
        case notSupported = 0x05
    }

    /// Parse a 64-byte reply body read back from the device.
    public struct Reply: Equatable, Sendable {
        public var status: UInt8
        public var transactionId: UInt8
        public var dataSize: UInt8
        public var commandClass: UInt8
        public var commandId: UInt8
        public var args: [UInt8]

        public var isSuccess: Bool { status == ReplyStatus.success.rawValue }

        public init?(body: [UInt8]) {
            guard body.count == RazerReport.bodyLength else { return nil }
            status = body[0]
            transactionId = body[1]
            dataSize = body[5]
            commandClass = body[6]
            commandId = body[7]
            args = Array(body[8..<(8 + Int(min(dataSize, UInt8(RazerReport.maxArgs))))])
        }
    }
}

/// Chroma effect ids, as enumerated by Synapse 4 (`NEW_CHROMA_EFFECT_ID`).
public enum ChromaEffect: UInt8, CaseIterable, Sendable {
    case off = 0
    case `static` = 1
    case breathing = 2
    case spectrum = 3
    case wave = 4
    case reactive = 5
    case basicRipple = 6
    case starlight = 7
    case customFrame = 8
    case fire = 9
    case audioMeter = 10
    case immersive = 11
    case wheel = 12
}

/// One RGB color.
public struct RGB: Equatable, Sendable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }

    /// Parse `"RRGGBB"` (with optional leading `#`).
    public init?(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF))
    }

    public var hex: String { String(format: "%02X%02X%02X", r, g, b) }
}

/// Builders for the commands the Seiren V3 Pro understands. Each returns a
/// `RazerReport`; the caller supplies the rolling transaction id.
///
/// Header constants are `[data size, command class, command id]`, verbatim from
/// Synapse's command table (docs/PROTOCOL.md §6.2).
public enum RazerCommand {

    // MARK: Device class (0x00)

    /// `[0x02, 0x00, 0x81]` - firmware version; reply args = [major, minor].
    public static func getFirmwareVersion(txn: UInt8) -> RazerReport {
        RazerReport(transactionId: txn, dataSize: 2, commandClass: 0x00, commandId: 0x81, args: [])
    }

    /// `[0x16, 0x00, 0x82]` - serial number; reply args = ASCII serial.
    public static func getSerialNumber(txn: UInt8) -> RazerReport {
        RazerReport(transactionId: txn, dataSize: 0x16, commandClass: 0x00, commandId: 0x82, args: [])
    }

    /// `[0x02, 0x00, 0x84]` - current device mode.
    public static func getDeviceMode(txn: UInt8) -> RazerReport {
        RazerReport(transactionId: txn, dataSize: 2, commandClass: 0x00, commandId: 0x84, args: [])
    }

    /// `[0x02, 0x00, 0x04]` - device mode: 0 = normal, 3 = driver (software
    /// effects). Synapse puts the mic in mode 3 while it runs.
    public static func setDeviceMode(_ mode: UInt8, txn: UInt8) -> RazerReport {
        RazerReport(transactionId: txn, dataSize: 2, commandClass: 0x00, commandId: 0x04, args: [mode, 0])
    }

    // MARK: Chroma class (0x0F)

    /// `[0x50, 0x0F, 0x02]` - select an effect. Args are
    /// `[profile, region, effect, flags, rate, colorCount, r,g,b, ...]` and the
    /// data size shrinks to the used length (Synapse sends 6 + 3n).
    public static func setEffect(_ effect: ChromaEffect,
                                 colors: [RGB] = [],
                                 profileId: UInt8 = 0,
                                 regionId: UInt8 = 0,
                                 flags: UInt8 = 0,
                                 rate: UInt8 = 0,
                                 txn: UInt8) -> RazerReport {
        var args: [UInt8] = [profileId, regionId, effect.rawValue, flags, rate, UInt8(colors.count)]
        for c in colors { args += [c.r, c.g, c.b] }
        return RazerReport(transactionId: txn, dataSize: UInt8(args.count),
                           commandClass: 0x0F, commandId: 0x02, args: args)
    }

    /// `[0x50, 0x0F, 0x03]` - upload one row of a custom frame. Args are
    /// `[profile, region, row, startCol, endCol, r,g,b × n]`; data size is
    /// 5 + 3n. The V3 Pro's ring is row 0, columns 0...11. Follow with
    /// `setEffect(.customFrame)` to display the uploaded frame.
    public static func customFrameRow(_ colors: [RGB],
                                      row: UInt8 = 0,
                                      startColumn: UInt8 = 0,
                                      profileId: UInt8 = 0,
                                      regionId: UInt8 = 0,
                                      txn: UInt8) -> RazerReport {
        precondition(!colors.isEmpty)
        var args: [UInt8] = [profileId, regionId, row,
                             startColumn, startColumn + UInt8(colors.count) - 1]
        for c in colors { args += [c.r, c.g, c.b] }
        return RazerReport(transactionId: txn, dataSize: UInt8(args.count),
                           commandClass: 0x0F, commandId: 0x03, args: args)
    }

    /// `[0x03, 0x0F, 0x04]` - brightness. `percent` is 0...100, scaled to
    /// 0...255 the way Synapse does (`floor(pct / 100 * 255)`).
    public static func setBrightness(percent: Int,
                                     profileId: UInt8 = 0,
                                     regionId: UInt8 = 0,
                                     txn: UInt8) -> RazerReport {
        let clamped = min(max(percent, 0), 100)
        let raw = UInt8(clamped * 255 / 100)
        return RazerReport(transactionId: txn, dataSize: 3,
                           commandClass: 0x0F, commandId: 0x04,
                           args: [profileId, regionId, raw])
    }

    /// `[0x03, 0x0F, 0x84]` - read brightness back; reply args
    /// `[profile, region, 0...255]`.
    public static func getBrightness(profileId: UInt8 = 0,
                                     regionId: UInt8 = 0,
                                     txn: UInt8) -> RazerReport {
        RazerReport(transactionId: txn, dataSize: 3,
                    commandClass: 0x0F, commandId: 0x84, args: [profileId, regionId])
    }
}

/// Physical facts about the Seiren V3 Pro's lighting, from Razer's device
/// manifest (`DeviceManifest_1422_0.json`): a single ring of 12 RGB LEDs,
/// addressed as custom-frame row 0, columns 0...11.
public enum SeirenV3ProLighting {
    public static let ledCount = 12
    public static let hidReportID: UInt8 = 0x07
}
