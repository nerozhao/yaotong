import Foundation
import CoreGraphics
import os.log

/// A single activity event detected by the monitor.
struct ActivityEvent: Equatable {
    enum Kind: String {
        case mouseClick = "鼠标点击"
        case mouseMove  = "鼠标移动"
        case keyPress   = "键盘按键"
        case scroll     = "滚轮滚动"
        case tablet     = "触摸板"
        case other      = "其他输入"
    }
    let kind: Kind
}

/// Thin wrapper around `CGEventSource.secondsSinceLastEventType` so the
/// state machine and tests can both depend on a small protocol rather
/// than the C API directly. Also detects *what kind* of activity just
/// happened (mouse / keyboard / scroll / etc.) by comparing the seconds-
/// since reading across several event types between calls.
protocol ActivityProviding {
    /// Seconds since the last input event of any kind.
    func secondsSinceLastInput() -> TimeInterval

    /// If a new input event has happened since the previous call, return
    /// a description of its kind. Returns `nil` when nothing changed.
    /// Implementations are expected to be called once per tick.
    func latestActivity() -> ActivityEvent?
}

/// Real implementation backed by `CGEventSource`.
final class SystemActivityMonitor: ActivityProviding {

    /// `kCGAnyInputEventType` (0xFFFFFFFF) — the "any input" sentinel.
    /// Not exposed as a Swift enum case, so we build it from the raw value.
    private static let anyInputEventType = CGEventType(rawValue: 0xFFFFFFFF)!

    /// (eventType, kind) pairs to compare between calls. Order is
    /// significant when several kinds change in the same tick — we
    /// report the first one we see.
    private static let trackedTypes: [(CGEventType, ActivityEvent.Kind)] = [
        (.leftMouseDown,  .mouseClick),
        (.rightMouseDown, .mouseClick),
        (.otherMouseDown, .mouseClick),
        (.mouseMoved,     .mouseMove),
        (.keyDown,        .keyPress),
        (.scrollWheel,    .scroll),
        (.tabletPointer,  .tablet),
    ]

    /// Last-seen "seconds since" value for each tracked event type.
    /// `nil` on the first call so we don't fire a spurious event for
    /// pre-existing history.
    private var lastSeen: [CGEventType: TimeInterval] = [:]

    func secondsSinceLastInput() -> TimeInterval {
        let seconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: Self.anyInputEventType
        )
        return max(0, seconds)
    }

    func latestActivity() -> ActivityEvent? {
        var detected: ActivityEvent?
        for (type, kind) in Self.trackedTypes {
            let current = CGEventSource.secondsSinceLastEventType(
                .combinedSessionState,
                eventType: type
            )
            // A decrease means an event of this type happened between the
            // previous call and now. We require a small drop to ignore
            // floating-point noise (events landing on the same tick).
            if let prev = lastSeen[type], current + 0.01 < prev {
                if detected == nil { detected = ActivityEvent(kind: kind) }
            }
            lastSeen[type] = current
        }
        return detected
    }
}
