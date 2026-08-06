import Foundation
import IOKit
import IOKit.hid

/// Errors from the lighting HID channel.
public enum LightingError: Error, Equatable {
    case noDevice
    /// TCC: the binary needs Privacy → Input Monitoring.
    case permissionDenied
    case io(IOReturn)
    /// The device replied, but not with success (status byte attached).
    case deviceRejected(UInt8)
    /// No matching reply arrived within the retry budget.
    case noReply
}

/// A conversation with one attached Seiren over its vendor HID channel
/// (interface 3, Feature report 0x07). Opens the device **non-exclusively** so
/// it never disturbs `AppleUSBAudio` or the audio streams.
///
/// Send path per command (mirrors Synapse's rzDevice25 flow):
///  1. SET_REPORT(Feature 0x07) with the 64-byte command body.
///  2. GET_REPORT(Feature 0x07) polled until the reply echoes our transaction
///     id (Synapse polls every ~5 ms, up to ~10 times).
public final class LightingSession {
    /// How the 64-byte body is framed for `IOHIDDeviceSetReport`. macOS is
    /// genuinely ambiguous here: the HID spec says a control transfer's data
    /// stage excludes the report ID, but hidapi's macOS backend passes numbered
    /// reports **with** the ID as byte 0 - and whether the descriptor's
    /// declared 64 bytes include the ID decides if the body must shrink to 63.
    /// The first command self-calibrates: each candidate is tried until the
    /// device echoes a valid reply, and the winner sticks for the session.
    ///
    /// Confirmed on a real V3 Pro (serial round-trip, 2026-08-05): `.prefixed`
    /// wins - so it goes first and normally resolves on the first try; the
    /// rest remain as fallbacks for other models/macOS versions.
    public enum Framing: String, CaseIterable, Sendable {
        case prefixed = "report ID + 64-byte body"
        case bare = "64-byte body, no report-ID prefix"
        case prefixedTrimmed = "report ID + 63-byte body"
        case bareTrimmed = "63-byte body, no report-ID prefix"

        func wireBytes(for body: [UInt8]) -> [UInt8] {
            switch self {
            case .bare: return body
            case .prefixed: return [SeirenV3ProLighting.hidReportID] + body
            case .prefixedTrimmed:
                return [SeirenV3ProLighting.hidReportID] + body.dropLast()
            case .bareTrimmed: return Array(body.dropLast())
            }
        }
    }

    private let device: IOHIDDevice
    private var opened = false
    private var txn: UInt8 = 0
    /// Resolved by the first successful exchange; nil while uncalibrated.
    public private(set) var framing: Framing?
    /// Raw bytes of the most recent GET_REPORT, for diagnostics on failure.
    public private(set) var lastRead: [UInt8] = []

    /// Wrap (and open) a HID device. Fails with `.permissionDenied` when Input
    /// Monitoring hasn't been granted to the calling binary.
    public init(device: IOHIDDevice) throws {
        self.device = device
        let r = IOHIDDeviceOpen(device, 0)   // 0 = kIOHIDOptionsTypeNone
        guard r == kIOReturnSuccess || r == kIOReturnExclusiveAccess else {
            throw r == kIOReturnNotPermitted
                ? LightingError.permissionDenied : LightingError.io(r)
        }
        opened = (r == kIOReturnSuccess)
    }

    deinit { if opened { IOHIDDeviceClose(device, 0) } }

    /// True when this HID device (collection) carries the Razer vendor channel.
    /// macOS splits every top-level collection of the mic's HID interface into
    /// its own IOHIDDevice (consumer keys, telephony, vendor ...); only the one
    /// exposing usage page 0xFF53 accepts the control reports.
    public static func carriesRazerChannel(_ device: IOHIDDevice, usagePage: Int) -> Bool {
        if let pairs = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString)
            as? [[String: Int]] {
            if pairs.contains(where: { $0[kIOHIDDeviceUsagePageKey] == usagePage }) {
                return true
            }
        }
        return (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString)
                as? Int) == usagePage
    }

    /// All attached Razer HID collection-devices with a registry PID.
    public static func candidateDevices(models: [DeviceModel] = DeviceRegistry.all())
        -> [IOHIDDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(
            manager, [kIOHIDVendorIDKey: SeirenController.razerVendorID] as CFDictionary)
        // No IOHIDManagerOpen: enumeration works without it, and the TCC-gated
        // step is the per-device open inside `LightingSession.init`.
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return []
        }
        let pids = Set(models.map { Int($0.pid) })
        return set.filter {
            let pid = IOHIDDeviceGetProperty($0, kIOHIDProductIDKey as CFString) as? Int
            return pid.map(pids.contains) ?? false
        }
    }

    /// Find the attached Seiren's **vendor-channel** collection and open a
    /// session to it. One-shot helper for CLI use; the menu-bar app uses
    /// `LightingController` for hotplug tracking instead.
    public static func openFirst(models: [DeviceModel] = DeviceRegistry.all()) throws -> LightingSession {
        let candidates = candidateDevices(models: models)
        guard !candidates.isEmpty else { throw LightingError.noDevice }
        let pages = Set(models.map { Int($0.hidUsagePage) })
        // Strongly prefer the collection that declares the Razer vendor usage
        // page; fall back to any candidate only if none does.
        let device = candidates.first(where: { d in
            pages.contains(where: { carriesRazerChannel(d, usagePage: $0) })
        }) ?? candidates[0]
        return try LightingSession(device: device)
    }

    private func nextTxn() -> UInt8 {
        txn = txn == 255 ? 1 : txn + 1
        return txn
    }

    /// Send one command and wait for the device's reply. The first command
    /// tries each `Framing` candidate until the device answers; later commands
    /// reuse the winner.
    @discardableResult
    public func send(_ make: (UInt8) -> RazerReport) throws -> RazerReport.Reply {
        let report = make(nextTxn())
        let candidates = framing.map { [$0] } ?? Framing.allCases
        for candidate in candidates {
            if let reply = try attempt(report, using: candidate) {
                framing = candidate
                guard reply.isSuccess else {
                    throw LightingError.deviceRejected(reply.status)
                }
                return reply
            }
        }
        throw LightingError.noReply
    }

    /// One SET_REPORT + reply-poll round with a specific framing. Returns nil
    /// when the device stays silent (so calibration can move on); throws only
    /// for hard errors.
    private func attempt(_ report: RazerReport, using framing: Framing) throws
        -> RazerReport.Reply? {
        let wire = framing.wireBytes(for: report.encoded())
        let r = wire.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature,
                                 CFIndex(SeirenV3ProLighting.hidReportID),
                                 $0.baseAddress!, wire.count)
        }
        if r == kIOReturnNotPermitted { throw LightingError.permissionDenied }
        // A size the kernel rejects just disqualifies this framing candidate.
        guard r == kIOReturnSuccess else {
            if self.framing != nil { throw LightingError.io(r) }
            return nil
        }

        // Poll for the echoed reply (~5 ms cadence, like Synapse, which
        // retries up to 30 times). BUSY (0x01) means "still processing" -
        // keep polling, it is not a rejection.
        for _ in 0..<30 {
            usleep(5_000)
            var buf = [UInt8](repeating: 0, count: RazerReport.bodyLength + 1)
            var len = CFIndex(buf.count)
            let g = buf.withUnsafeMutableBufferPointer {
                IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature,
                                     CFIndex(SeirenV3ProLighting.hidReportID),
                                     $0.baseAddress!, &len)
            }
            if g == kIOReturnNotPermitted { throw LightingError.permissionDenied }
            guard g == kIOReturnSuccess else {
                if self.framing != nil { throw LightingError.io(g) }
                return nil
            }
            lastRead = Array(buf.prefix(max(0, min(Int(len), buf.count))))
            if let reply = parseReply(from: buf, matching: report, framing: framing) {
                if reply.status == RazerReport.ReplyStatus.busy.rawValue { continue }
                return reply
            }
        }
        return nil
    }

    /// Parse a GET_REPORT buffer into the reply for `report`, tolerating both
    /// ID-stripped and ID-prefixed replies (the counterpart of the send-side
    /// ambiguity). A real reply echoes our transaction id AND command
    /// class/id, and carries a known status - anything else at a given offset
    /// is a misparse, not a match (the report-ID byte 0x07 read at the wrong
    /// offset can otherwise masquerade as a status).
    private func parseReply(from buf: [UInt8], matching report: RazerReport,
                            framing: Framing) -> RazerReport.Reply? {
        // With an ID-prefixed send framing the reply is ID-prefixed too, so
        // prefer that offset; keep the other as a fallback.
        let offsets: [Int]
        switch framing {
        case .prefixed, .prefixedTrimmed: offsets = [1, 0]
        case .bare, .bareTrimmed: offsets = [0, 1]
        }
        for offset in offsets {
            if offset == 1, buf.first != SeirenV3ProLighting.hidReportID { continue }
            var body = Array(buf.dropFirst(offset).prefix(RazerReport.bodyLength))
            if body.count < RazerReport.bodyLength {
                body += [UInt8](repeating: 0, count: RazerReport.bodyLength - body.count)
            }
            guard let reply = RazerReport.Reply(body: body),
                  reply.transactionId == report.transactionId,
                  reply.commandClass == report.commandClass,
                  reply.commandId == report.commandId,
                  RazerReport.ReplyStatus(rawValue: reply.status) != nil
            else { continue }
            return reply
        }
        return nil
    }

    // MARK: High-level commands

    public struct DeviceInfo: Sendable {
        public var firmware: String
        public var serial: String
        public var mode: UInt8
        public var brightnessPercent: Int?
    }

    /// Read-only identification pass - the safe first thing to run on new
    /// hardware. The serial doubles as an end-to-end check of the whole report
    /// format (it must match the sticker / Synapse's value).
    public func probe() throws -> DeviceInfo {
        let fw = try send { RazerCommand.getFirmwareVersion(txn: $0) }
        let serial = try send { RazerCommand.getSerialNumber(txn: $0) }
        let mode = try send { RazerCommand.getDeviceMode(txn: $0) }
        let brightness = try? send { RazerCommand.getBrightness(txn: $0) }
        let serialString = String(bytes: serial.args.prefix(while: { $0 != 0 }),
                                  encoding: .ascii) ?? "?"
        return DeviceInfo(
            firmware: fw.args.count >= 2 ? "v\(fw.args[0]).\(fw.args[1])" : "?",
            serial: serialString,
            mode: mode.args.first ?? 0,
            brightnessPercent: brightness.map { Int($0.args.count >= 3 ? $0.args[2] : 0) * 100 / 255 }
        )
    }

    public func setEffect(_ effect: ChromaEffect, colors: [RGB] = []) throws {
        try send { RazerCommand.setEffect(effect, colors: colors, txn: $0) }
    }

    public func setBrightness(percent: Int) throws {
        try send { RazerCommand.setBrightness(percent: percent, txn: $0) }
    }

    /// Upload and display a full 12-LED ring frame.
    public func showFrame(_ colors: [RGB]) throws {
        try send { RazerCommand.customFrameRow(colors, txn: $0) }
        try send { RazerCommand.setEffect(.customFrame, txn: $0) }
    }

    public func setDeviceMode(_ mode: UInt8) throws {
        try send { RazerCommand.setDeviceMode(mode, txn: $0) }
    }
}

// MARK: - App-level controller

public protocol LightingControllerDelegate: AnyObject {
    func lightingControllerDidChange(_ controller: LightingController)
}

/// What the user asked the lights to do. Persist-friendly.
public struct LightingState: Equatable, Sendable {
    public var effect: ChromaEffect
    public var color: RGB?
    public var brightnessPercent: Int

    public init(effect: ChromaEffect, color: RGB? = nil, brightnessPercent: Int = 100) {
        self.effect = effect
        self.color = color
        self.brightnessPercent = brightnessPercent
    }
}

/// Tracks Seiren hotplug on the main run loop and (re)applies the user's
/// lighting choice - lighting state is volatile on the device, so it must be
/// re-asserted every attach, like the monitor engine does for monitoring.
public final class LightingController {
    public weak var delegate: LightingControllerDelegate?

    public private(set) var deviceConnected = false
    public private(set) var lastError: LightingError?
    /// The state to keep asserted, or nil to leave the device untouched.
    public private(set) var desiredState: LightingState?

    private let manager: IOHIDManager
    private let pids: Set<Int>
    private let usagePages: Set<Int>
    private var currentDevice: IOHIDDevice?

    public init(models: [DeviceModel] = DeviceRegistry.all()) {
        pids = Set(models.map { Int($0.pid) })
        usagePages = Set(models.map { Int($0.hidUsagePage) })
        manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    }

    public func start() {
        IOHIDManagerSetDeviceMatching(
            manager, [kIOHIDVendorIDKey: SeirenController.razerVendorID] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<LightingController>.fromOpaque(context)
                .takeUnretainedValue().attached(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<LightingController>.fromOpaque(context)
                .takeUnretainedValue().removed(device)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(),
                                        CFRunLoopMode.defaultMode.rawValue)
        // Deliberately no IOHIDManagerOpen here: matching callbacks work
        // without it, and it is the *device* open that trips the Input
        // Monitoring permission. Deferring that to `assertDesiredState()` means
        // users who never touch Lighting never see the TCC prompt.
    }

    /// Apply (and remember) a lighting state. Passing the state again after a
    /// replug is handled automatically.
    public func apply(_ state: LightingState) {
        desiredState = state
        assertDesiredState()
    }

    private func attached(_ device: IOHIDDevice) {
        guard let pid = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int,
              pids.contains(pid),
              // Each top-level HID collection arrives as its own device; only
              // the Razer vendor-channel collection takes control reports.
              usagePages.contains(where: {
                  LightingSession.carriesRazerChannel(device, usagePage: $0)
              })
        else { return }
        currentDevice = device
        deviceConnected = true
        assertDesiredState()
        notify()
    }

    private func removed(_ device: IOHIDDevice) {
        guard device === currentDevice else { return }
        currentDevice = nil
        deviceConnected = false
        notify()
    }

    private func assertDesiredState() {
        guard let state = desiredState else { return }
        guard let device = currentDevice else { lastError = .noDevice; notify(); return }
        do {
            let session = try LightingSession(device: device)
            try session.setBrightness(percent: state.brightnessPercent)
            switch state.effect {
            case .static:
                try session.setEffect(.static, colors: state.color.map { [$0] } ?? [RGB(0, 255, 0)])
            case .breathing:
                try session.setEffect(.breathing, colors: state.color.map { [$0] } ?? [])
            default:
                try session.setEffect(state.effect)
            }
            lastError = nil
        } catch let e as LightingError {
            lastError = e
        } catch {
            lastError = .noReply
        }
        notify()
    }

    private func notify() { delegate?.lightingControllerDidChange(self) }
}
