import Foundation

/// The device topology the installed Seiren FX 3.0 driver must publish, checked
/// by `seiren-probe driver-check`. Core Audio reads stay in the probe so the
/// table and the pass or fail rules here are pure functions with unit tests.
public enum DriverCheck {
    /// One device as Core Audio reports it.
    public struct Device: Equatable {
        public var isHidden: Bool
        /// Channel count of each input stream, in stream order.
        public var inputStreamChannels: [Int]
        /// Channel count of each output stream, in stream order.
        public var outputStreamChannels: [Int]
        public var canBeDefaultOutput: Bool
        public var sampleRates: [ClosedRange<Double>]

        public init(isHidden: Bool, inputStreamChannels: [Int], outputStreamChannels: [Int],
                    canBeDefaultOutput: Bool, sampleRates: [ClosedRange<Double>]) {
            self.isHidden = isHidden
            self.inputStreamChannels = inputStreamChannels
            self.outputStreamChannels = outputStreamChannels
            self.canBeDefaultOutput = canBeDefaultOutput
            self.sampleRates = sampleRates
        }
    }

    /// The visible microphones apps record from.
    public static let visibleUIDs = [MonitorEngine.fxDeviceUID, MonitorEngine.streamMixDeviceUID]
    /// The hidden output devices the app plays into, found only by UID.
    public static let feederUIDs = [MonitorEngine.fxFeederUID, MonitorEngine.streamMixFeederUID]
    public static let requiredSampleRates: [Double] = [44100, 48000, 88200, 96000]

    /// One line per failed check, naming the device and the check. Empty means
    /// the driver passed. A nil entry is a device Core Audio did not find.
    public static func failures(_ devices: [String: Device?]) -> [String] {
        var failures: [String] = []
        for uid in visibleUIDs + feederUIDs {
            let isFeeder = feederUIDs.contains(uid)
            guard let device = devices[uid] ?? nil else {
                failures.append(isFeeder
                    ? "\(uid): does not resolve through kAudioHardwarePropertyTranslateUIDToDevice"
                    : "\(uid): not in the system device list")
                continue
            }
            if device.isHidden != isFeeder {
                failures.append("\(uid): is \(device.isHidden ? "hidden" : "visible"), "
                    + "expected \(isFeeder ? "hidden" : "visible")")
            }
            let (inputs, outputs) = isFeeder ? ([], [2]) : ([2], [])
            if device.inputStreamChannels != inputs {
                failures.append("\(uid): input streams \(describe(device.inputStreamChannels)), "
                    + "expected \(describe(inputs))")
            }
            if device.outputStreamChannels != outputs {
                failures.append("\(uid): output streams \(describe(device.outputStreamChannels)), "
                    + "expected \(describe(outputs))")
            }
            if device.canBeDefaultOutput {
                failures.append("\(uid): can become the default output device")
            }
            let missing = requiredSampleRates.filter { rate in
                !device.sampleRates.contains { $0.contains(rate) }
            }
            if !missing.isEmpty {
                failures.append("\(uid): sample rates missing \(missing.map(kHz).joined(separator: ", ")) kHz")
            }
        }
        return failures
    }

    /// One row per expected device, missing ones included.
    public static func table(_ devices: [String: Device?]) -> String {
        let header = ["UID", "hidden", "inputs", "outputs", "default output", "sample rates (kHz)"]
        let rows = (visibleUIDs + feederUIDs).map { uid -> [String] in
            guard let device = devices[uid] ?? nil else {
                return [uid, "-", "-", "-", "-", "missing"]
            }
            return [uid, device.isHidden ? "yes" : "no",
                    describe(device.inputStreamChannels), describe(device.outputStreamChannels),
                    device.canBeDefaultOutput ? "yes" : "no",
                    device.sampleRates.isEmpty ? "none" : device.sampleRates.map(describe).joined(separator: ", ")]
        }
        let widths = header.indices.map { column in
            ([header] + rows).map { $0[column].count }.max() ?? 0
        }
        return ([header] + rows).map { row in
            zip(row, widths).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
                .trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    /// Stream count plus each stream's channels, for example "1 (2 ch)".
    private static func describe(_ streams: [Int]) -> String {
        streams.isEmpty ? "0" : "\(streams.count) (\(streams.map { "\($0) ch" }.joined(separator: ", ")))"
    }

    private static func describe(_ range: ClosedRange<Double>) -> String {
        range.lowerBound == range.upperBound
            ? kHz(range.lowerBound) : "\(kHz(range.lowerBound))-\(kHz(range.upperBound))"
    }

    private static func kHz(_ rate: Double) -> String {
        let value = rate / 1000
        return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
