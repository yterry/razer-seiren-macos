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
    private let device: IOHIDDevice
    private var opened = false
    private var txn: UInt8 = 0
    /// The feature-report payload size the device's descriptor declares. The
    /// V3 Pro's Razer channel is 64 bytes; if a descriptor says 63 we drop the
    /// trailing reserved byte (the CRC sits at offset 62, so nothing is lost).
    private let reportSize: Int

    /// Wrap (and open) a HID device. Fails with `.permissionDenied` when Input
    /// Monitoring hasn't been granted to the calling binary.
    public init(device: IOHIDDevice) throws {
        self.device = device
        let declared = IOHIDDeviceGetProperty(
            device, kIOHIDMaxFeatureReportSizeKey as CFString) as? Int
        reportSize = min(declared.flatMap { $0 > 0 ? $0 : nil } ?? RazerReport.bodyLength,
                         RazerReport.bodyLength)
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

    /// Send one command and wait for the device's reply.
    @discardableResult
    public func send(_ make: (UInt8) -> RazerReport) throws -> RazerReport.Reply {
        let report = make(nextTxn())
        // Per HID convention on macOS the buffer excludes the report ID; it is
        // passed separately. (hidapi does exactly this for numbered reports.)
        // Truncate to the descriptor's report size when it is smaller than our
        // 64-byte body - only the reserved padding byte can be affected.
        let body = Array(report.encoded().prefix(reportSize))
        let r = body.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature,
                                 CFIndex(SeirenV3ProLighting.hidReportID),
                                 $0.baseAddress!, body.count)
        }
        guard r == kIOReturnSuccess else {
            throw r == kIOReturnNotPermitted
                ? LightingError.permissionDenied : LightingError.io(r)
        }

        // Poll for the echoed transaction id (~5 ms cadence, like Synapse).
        for _ in 0..<10 {
            usleep(5_000)
            var buf = [UInt8](repeating: 0, count: reportSize)
            var len = CFIndex(buf.count)
            let g = buf.withUnsafeMutableBufferPointer {
                IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature,
                                     CFIndex(SeirenV3ProLighting.hidReportID),
                                     $0.baseAddress!, &len)
            }
            guard g == kIOReturnSuccess else { throw LightingError.io(g) }
            // Re-pad so the reply parser always sees a full 64-byte body.
            let full = buf + [UInt8](repeating: 0, count: RazerReport.bodyLength - buf.count)
            guard let reply = RazerReport.Reply(body: full),
                  reply.transactionId == report.transactionId else { continue }
            guard reply.isSuccess else { throw LightingError.deviceRejected(reply.status) }
            return reply
        }
        throw LightingError.noReply
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
