import Foundation
import CoreGraphics

/// Thin wrapper around `CGEventSource.secondsSinceLastEventType` so the
/// state machine and tests can both depend on a small protocol rather
/// than the C API directly.
protocol ActivityProviding {
    /// Seconds since the last combined input event (mouse, keyboard, scroll).
    /// Returns 0 if the query is unavailable.
    func secondsSinceLastInput() -> TimeInterval
}

struct SystemActivityMonitor: ActivityProviding {

    /// `kCGAnyInputEventType` from CGEventTypes.h — "any input" sentinel.
    /// Not exposed as a Swift enum case, so we construct it from the raw value.
    private static let anyInputEventType = CGEventType(rawValue: 0xFFFFFFFF)!

    func secondsSinceLastInput() -> TimeInterval {
        let seconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: Self.anyInputEventType
        )
        // CGEventSource returns a negative value if the event source is
        // unavailable — guard against that rather than letting the
        // state machine misinterpret it as "user was active hours ago".
        return max(0, seconds)
    }
}
