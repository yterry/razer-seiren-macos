import Foundation
import IOKit
import IOKit.hid

public protocol SeirenControllerDelegate: AnyObject {
    func seirenControllerDidChange(_ controller: SeirenController)
}

/// Owns the IOHIDManager, detects a known Seiren, and sends it commands.
///
/// Key design points:
///  - The HID manager is opened **non-exclusively** (option `0` =
///    `kIOHIDOptionsTypeNone`) so it coexists with `AppleUSBAudio` and never
///    interrupts the mic's audio streams.
///  - Device state is volatile across unplug/reboot, so we re-assert the
///    desired monitoring state every time the device re-attaches.
public final class SeirenController {
    public enum ApplyResult: Equatable {
        case ok
        case noop               // nothing to assert (monitoring off / fresh attach)
        case notCaptured        // model known but no command bytes yet
        case noDevice
        case permissionDenied   // TCC: Input Monitoring not granted
        case failed(IOReturn)
    }

    public static let razerVendorID = 0x1532

    public weak var delegate: SeirenControllerDelegate?
    public private(set) var connectedModel: DeviceModel?
    public private(set) var monitoringOn = false
    public private(set) var lastResult: ApplyResult = .noDevice

    private let manager: IOHIDManager
    private let models: [DeviceModel]
    private var currentDevice: IOHIDDevice?

    public init(models: [DeviceModel] = DeviceRegistry.all()) {
        self.models = models
        // option 0 = kIOHIDOptionsTypeNone (non-exclusive / non-seizing).
        manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    }

    public func start() {
        let match = [kIOHIDVendorIDKey: Self.razerVendorID] as CFDictionary
        IOHIDManagerSetDeviceMatching(manager, match)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<SeirenController>.fromOpaque(context)
                .takeUnretainedValue().deviceAttached(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<SeirenController>.fromOpaque(context)
                .takeUnretainedValue().deviceRemoved(device)
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(),
                                        CFRunLoopMode.defaultMode.rawValue)

        // Non-exclusive open. May fail with kIOReturnNotPermitted until the
        // binary is granted Privacy → Input Monitoring.
        let opened = IOHIDManagerOpen(manager, 0)
        if opened != kIOReturnSuccess {
            lastResult = (opened == kIOReturnNotPermitted) ? .permissionDenied : .failed(opened)
            notify()
        }
    }

    /// User intent: turn monitoring on/off. Sends the captured command if the
    /// model supports it; otherwise reports `.notCaptured`.
    public func setMonitoring(_ on: Bool) {
        monitoringOn = on
        sendCurrentState()
    }

    // MARK: - Hotplug

    private func deviceAttached(_ device: IOHIDDevice) {
        guard let pid = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int,
              let model = models.first(where: { Int($0.pid) == pid })
        else { return }   // some other Razer device (keyboard/mouse) — ignore
        currentDevice = device
        connectedModel = model
        // Re-assert desired state (device forgets it across reconnects).
        if monitoringOn {
            sendCurrentState()
        } else {
            lastResult = .noop
            notify()
        }
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        guard let pid = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int,
              Int(connectedModel?.pid ?? 0) == pid
        else { return }
        currentDevice = nil
        connectedModel = nil
        lastResult = .noDevice
        notify()
    }

    // MARK: - Sending

    private func sendCurrentState() {
        guard let model = connectedModel, let device = currentDevice else {
            lastResult = .noDevice; notify(); return
        }
        guard let frame = monitoringOn ? model.commands.monitorOn : model.commands.monitorOff else {
            lastResult = .notCaptured; notify(); return
        }
        if let handshake = model.commands.handshake {
            for f in handshake { _ = send(f, to: device) }
        }
        lastResult = send(frame, to: device)
        notify()
    }

    private func send(_ frame: CommandFrame, to device: IOHIDDevice) -> ApplyResult {
        let reportType: IOHIDReportType = (frame.type == .feature)
            ? kIOHIDReportTypeFeature : kIOHIDReportTypeOutput
        // hidapi convention: buffer carries the report ID as byte 0 for numbered reports.
        var buf: [UInt8] = [frame.reportID]
        buf.append(contentsOf: frame.bytes)
        let r = IOHIDDeviceSetReport(device, reportType, CFIndex(frame.reportID), buf, buf.count)
        switch r {
        case kIOReturnSuccess:      return .ok
        case kIOReturnNotPermitted: return .permissionDenied
        default:                    return .failed(r)
        }
    }

    private func notify() { delegate?.seirenControllerDidChange(self) }
}
