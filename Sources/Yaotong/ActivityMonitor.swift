import Foundation
import CoreGraphics

/// A single activity event detected by the monitor.
struct ActivityEvent: Equatable {
    enum Kind: String {
        case mouseClick  = "鼠标点击"
        case mouseDrag   = "鼠标拖拽"
        case mouseMove   = "鼠标移动"
        case keyPress    = "键盘按键"
        case modifierKey = "修饰键"
        case systemKey   = "系统键"
        case scroll      = "滚轮滚动"
        case tablet      = "触摸板"
        case other       = "其他输入"
    }
    let kind: Kind
}

/// Thin wrapper around `CGEventSource.secondsSinceLastEventType`.
///
/// The state machine only needs the "any input" idle reading. The
/// per-type readings are queried **only** when an event is actually
/// detected, so the steady-state cost is one `CGEventSource` call
/// per tick instead of twelve.
final class SystemActivityMonitor {

    /// `kCGAnyInputEventType` (0xFFFFFFFF) — the "any input" sentinel.
    /// Not exposed as a Swift enum case, so we build it from the raw value.
    private static let anyInputEventType = CGEventType(rawValue: 0xFFFFFFFF)!

    /// Order matters: when several kinds fire in the same tick we
    /// report the first one we see. More specific intents (clicks,
    /// drags, key presses, modifier / system keys) come before
    /// ambient movement (mouse move, tablet pointer) so a click
    /// during continuous mouse motion is reported as a click.
    ///
    /// `flagsChanged` is what fires for Shift / Ctrl / Opt / Cmd /
    /// Caps Lock — not `keyDown`. Without it, modifier-only activity
    /// falls through to `.other`. Same for `systemDefined`, which
    /// covers media / brightness / volume keys.
    private static let trackedTypes: [(CGEventType, ActivityEvent.Kind)] = [
        (.leftMouseDown,      .mouseClick),
        (.rightMouseDown,     .mouseClick),
        (.otherMouseDown,     .mouseClick),
        (.leftMouseDragged,   .mouseDrag),
        (.rightMouseDragged,  .mouseDrag),
        (.otherMouseDragged,  .mouseDrag),
        (.keyDown,            .keyPress),
        (.flagsChanged,       .modifierKey),
        // `kCGEventSystemDefined` (raw 14) — media / brightness / volume.
        (CGEventType(rawValue: 14)!, .systemKey),
        (.scrollWheel,        .scroll),
        (.mouseMoved,         .mouseMove),
        (.tabletPointer,      .tablet),
    ]

    /// A per-type reading below this means the type fired in the
    /// latter half of the previous tick window. Tuned for a 1Hz
    /// tick loop — 0.5s catches events from "just now" up to half a
    /// second ago, while still rejecting ambient noise (idle for
    /// several seconds).
    private static let eventThreshold: TimeInterval = 0.5

    /// "Seconds since any input" reading from the previous tick.
    /// A decrease between ticks is the signal that *something* happened.
    /// `nil` on the first call so we don't fire a spurious event for
    /// pre-existing history.
    private var lastAny: TimeInterval?

    /// Sample the system. Call exactly once per tick.
    /// - Returns: `idleSeconds` (for the state machine) and an optional
    ///   `event` (for logging). The event is only non-nil on ticks where
    ///   an input was actually detected.
    @discardableResult
    func sample() -> (idleSeconds: TimeInterval, event: ActivityEvent?) {
        let current = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: Self.anyInputEventType
        )
        let event = detectEvent(currentIdle: current)
        lastAny = current
        return (max(0, current), event)
    }

    /// Returns a non-nil `ActivityEvent` only when the "any input"
    /// reading just decreased. Then (and only then) we pay the
    /// per-type queries to identify the kind. A reading below the
    /// threshold for a specific type means that type just happened.
    private func detectEvent(currentIdle: TimeInterval) -> ActivityEvent? {
        guard let prev = lastAny, currentIdle + 0.01 < prev else {
            return nil
        }
        for (type, kind) in Self.trackedTypes {
            let c = CGEventSource.secondsSinceLastEventType(
                .combinedSessionState,
                eventType: type
            )
            if c < Self.eventThreshold {
                return ActivityEvent(kind: kind)
            }
        }
        return ActivityEvent(kind: .other)
    }
}
