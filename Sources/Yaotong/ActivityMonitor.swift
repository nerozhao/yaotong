import Foundation
import CoreGraphics

/// Thin wrapper around `CGEventSource.secondsSinceLastEventType`.
///
/// The state machine only needs the "any input" idle reading — the
/// per-type breakdown is gone (it was only used for log throttling,
/// which is now suppressed). One CG call per tick, always.
final class SystemActivityMonitor {

    /// `kCGAnyInputEventType` (0xFFFFFFFF) — the "any input" sentinel.
    /// Not exposed as a Swift enum case, so we build it from the raw value.
    private static let anyInputEventType = CGEventType(rawValue: 0xFFFFFFFF)!

    /// Sample the system. Call exactly once per tick.
    /// - Returns: seconds since the last user input event of any kind.
    @discardableResult
    func sample() -> TimeInterval {
        let current = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: Self.anyInputEventType
        )
        return max(0, current)
    }
}
