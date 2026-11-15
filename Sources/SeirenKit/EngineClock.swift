import Foundation

/// A timer scheduled on an `EngineClock`. Cancelling stops every later firing.
@MainActor
package protocol EngineTimer: AnyObject {
    func cancel()
}

/// The time `MonitorEngine` reads and the timers it waits on, so tests can
/// move time forward without sleeping. `SystemClock` is the real implementation.
@MainActor
package protocol EngineClock: AnyObject {
    /// Seconds since boot.
    var uptime: TimeInterval { get }
    /// Runs `action` on the main actor after `interval` seconds, and again
    /// every `interval` seconds when `repeats` is true.
    func schedule(after interval: TimeInterval, repeats: Bool,
                  _ action: @escaping @MainActor @Sendable () -> Void) -> any EngineTimer
}

@MainActor
package final class SystemClock: EngineClock {
    private final class SystemTimer: EngineTimer {
        private let timer: Timer

        init(_ timer: Timer) { self.timer = timer }

        func cancel() { timer.invalidate() }
    }

    package init() {}

    package var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    package func schedule(after interval: TimeInterval, repeats: Bool,
                          _ action: @escaping @MainActor @Sendable () -> Void) -> any EngineTimer {
        let timer = Timer(timeInterval: interval, repeats: repeats) { _ in
            Task { @MainActor in action() }
        }
        // Common modes: a default-mode timer stops while the menu is open, so
        // a call that ended during that time would keep the mic open until
        // the menu closed.
        RunLoop.main.add(timer, forMode: .common)
        return SystemTimer(timer)
    }
}
