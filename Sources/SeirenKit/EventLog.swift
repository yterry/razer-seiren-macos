import Foundation
import os

/// The app's always-on record of engine, route, standby, device, mixer,
/// lighting and power events. Each event goes to the unified log under
/// `subsystem` and, unless it is a debug line, into a buffer of the most
/// recent `capacity` entries that "Copy Diagnostics" reads.
/// `SEIREN_MONITOR_DEBUG` also mirrors every line to stderr.
///
/// Main actor only. No IOProc, and nothing an IOProc calls, may touch it.
@MainActor
public final class EventLog {
    public enum Category: String, Sendable {
        case engine, route, standby, auto, devices, mixer, lighting, system
    }

    public struct Entry: Equatable, Sendable, CustomStringConvertible {
        public var date: Date
        public var category: Category
        /// The message with private parts shown as `<private>`.
        public var message: String

        private static let timestamp = Date.ISO8601FormatStyle(
            dateSeparator: .dash, dateTimeSeparator: .space, timeSeparator: .colon,
            timeZoneSeparator: .omitted, includingFractionalSeconds: true, timeZone: .current)

        public var description: String {
            "\(date.formatted(Self.timestamp)) [\(category.rawValue)] \(message)"
        }
    }

    /// Event text built by string interpolation. Private parts, such as a
    /// device UID or the name of a device that is neither a Seiren nor this
    /// app's own, are stored as private data in the unified log and shown as
    /// `<private>` in `recent`.
    public struct Message: ExpressibleByStringInterpolation, Sendable {
        fileprivate struct Part: Sendable {
            var text: String
            var isPrivate: Bool
        }

        public struct StringInterpolation: StringInterpolationProtocol {
            fileprivate var parts: [Part] = []

            public init(literalCapacity: Int, interpolationCount: Int) {}

            public mutating func appendLiteral(_ literal: String) {
                parts.append(Part(text: literal, isPrivate: false))
            }

            public mutating func appendInterpolation<T>(_ value: T) {
                appendLiteral(String(describing: value))
            }

            public mutating func appendInterpolation(private value: String) {
                parts.append(Part(text: value, isPrivate: true))
            }

            /// "Name (USB, 1 in / 2 out streams)", with the name private
            /// unless the report would show it.
            public mutating func appendInterpolation(device: DiagnosticsSnapshot.Device) {
                if DiagnosticsReport.showsName(of: device) {
                    appendLiteral(device.name)
                } else {
                    appendInterpolation(private: device.name)
                }
                appendLiteral(" (\(DiagnosticsReport.transportName(device.transport)), " +
                              "\(device.inputStreams) in / \(device.outputStreams) out streams)")
            }
        }

        fileprivate var parts: [Part]

        public init(stringLiteral value: String) {
            parts = [Part(text: value, isPrivate: false)]
        }

        public init(stringInterpolation: StringInterpolation) {
            parts = stringInterpolation.parts
        }

        /// Lets a long message span lines like a String does.
        public static func + (lhs: Message, rhs: Message) -> Message {
            var joined = lhs
            joined.parts += rhs.parts
            return joined
        }

        fileprivate var plain: String { parts.map(\.text).joined() }

        fileprivate static func redacted(_ parts: ArraySlice<Part>) -> String {
            parts.map { $0.isPrivate ? "<private>" : $0.text }.joined()
        }
    }

    public static let shared = EventLog()
    public static let capacity = 300
    public static let subsystem = "com.yterry.seiren-mac"

    /// Recent entries, oldest first, at most `capacity`.
    public private(set) var recent: [Entry] = []

    private let mirrorsToStderr = ProcessInfo.processInfo.environment["SEIREN_MONITOR_DEBUG"] != nil

    init() {}

    /// Record an event: unified log at the default level, plus `recent`.
    public func log(category: Category, message: Message) {
        write(category: category, message: message, level: .default)
        recent.append(Entry(date: Date(), category: category, message: Message.redacted(message.parts[...])))
        if recent.count > Self.capacity { recent.removeFirst(recent.count - Self.capacity) }
    }

    /// Frequent detail, such as each recorder poll: unified log at the debug
    /// level only, never `recent`.
    public func debug(category: Category, message: Message) {
        write(category: category, message: message, level: .debug)
    }

    private func write(category: Category, message: Message, level: OSLogType) {
        let logger = Logger(subsystem: Self.subsystem, category: category.rawValue)
        // os.Logger sets privacy per interpolated argument, so a message
        // splits around its first private part; any later private part is
        // already redacted in the tail.
        if let index = message.parts.firstIndex(where: \.isPrivate) {
            let head = Message.redacted(message.parts[..<index])
            let secret = message.parts[index].text
            let tail = Message.redacted(message.parts[(index + 1)...])
            logger.log(level: level, "\(head, privacy: .public)\(secret, privacy: .private)\(tail, privacy: .public)")
        } else {
            logger.log(level: level, "\(message.plain, privacy: .public)")
        }
        if mirrorsToStderr {
            let line = Entry(date: Date(), category: category, message: message.plain)
            fputs("\(line)\n", stderr)
        }
    }
}
