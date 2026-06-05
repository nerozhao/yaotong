import Foundation

/// The icon state the menu bar can show.
enum StatusState: Equatable {
    /// User is working (or resting) and has not yet hit the work threshold.
    case working
    /// User has worked continuously past the work threshold.
    case overtime
}

/// Reason the state machine's state changed on a given tick. Surfaced to
/// the app's log so we can explain *why* the icon flipped.
enum StateMachineEvent: Equatable {
    /// No state-affecting event this tick.
    case none
    /// User had no work session, then started one (typed / moved mouse).
    case workSessionStarted
    /// Work session ended because the user rested long enough.
    /// `idleSeconds` is how long they were idle when we detected it.
    case workSessionReset(idleSeconds: TimeInterval)
    /// Work session crossed the overtime threshold.
    /// `elapsed` is how long they worked in seconds.
    case overtimeReached(elapsed: TimeInterval)
    /// A tick happened while paused — we report this so the log shows the
    /// pause is being honored.
    case paused

    /// Human-readable single-line description, suitable for `LogStore.log`.
    var logMessage: String {
        switch self {
        case .none:
            return ""
        case .workSessionStarted:
            return "工作会话开始：检测到活动"
        case .workSessionReset(let idle):
            let mins = Int(idle / 60)
            let secs = Int(idle.truncatingRemainder(dividingBy: 60))
            return "休息判定：已空闲 \(mins)分\(secs)秒，重置工作计时器"
        case .overtimeReached(let elapsed):
            let mins = Int(elapsed / 60)
            let secs = Int(elapsed.truncatingRemainder(dividingBy: 60))
            return "超时判定：已工作 \(mins)分\(secs)秒，达到工作阈值"
        case .paused:
            return "暂停中：跳过本次 tick"
        }
    }
}

/// Pure state machine. Holds no AppKit / system dependencies so it can be
/// unit tested with synthetic clocks.
///
/// Inputs each tick:
///   - `now`: the current wall-clock time
///   - `idleSeconds`: seconds since the last input event (from CGEventSource)
///   - `isPaused`: whether the user has paused monitoring
///
/// Outputs:
///   - return value: working vs overtime
///   - `lastEvent`: what happened this tick (for logging)
///   - `workStart` / `workDuration`: progress through the current session
final class StateMachine {

    /// Time below which a tick is considered "the user is actively doing
    /// something right now". Anything longer is treated as "no input".
    static let activityThreshold: TimeInterval = 1.0

    private(set) var workStart: Date?
    private(set) var lastActivity: Date?
    private(set) var lastEvent: StateMachineEvent = .none

    let workThreshold: TimeInterval
    let restThreshold: TimeInterval

    init(workMinutes: Int, restMinutes: Int) {
        self.workThreshold = TimeInterval(workMinutes * 60)
        self.restThreshold = TimeInterval(restMinutes * 60)
    }

    /// Apply a tick. Returns the resulting state. After the call,
    /// `lastEvent` describes what happened (for the log / debug panel).
    @discardableResult
    func tick(now: Date, idleSeconds: TimeInterval, isPaused: Bool) -> StatusState {
        // While paused, never advance the timer. We also forget any in-flight
        // work session so a long pause followed by a return to work starts
        // fresh — matches the spec: "暂停期间不计时".
        if isPaused {
            workStart = nil
            lastActivity = nil
            lastEvent = .paused
            return .working
        }

        // Has the user been idle long enough to count as rested?
        // Use `lastActivity` as the reference if we have one, otherwise fall
        // back to `now - idleSeconds` so we can detect the very first tick.
        let referenceActivity: Date
        if let last = lastActivity {
            referenceActivity = last
        } else {
            referenceActivity = now.addingTimeInterval(-idleSeconds)
        }
        let sinceActivity = now.timeIntervalSince(referenceActivity)

        if sinceActivity >= restThreshold {
            // User has been away long enough — treat as rested, reset work.
            workStart = nil
            lastActivity = referenceActivity
            lastEvent = .workSessionReset(idleSeconds: sinceActivity)
            return .working
        }

        // Is the user "active" this very second? If so, mark them active and
        // (re)start the work session if needed.
        if idleSeconds < Self.activityThreshold {
            lastActivity = now
            if workStart == nil {
                workStart = now
                lastEvent = .workSessionStarted
            } else {
                lastEvent = .none
            }
        } else {
            // The user is within the rest window but not actively typing this
            // second. Don't extend lastActivity — but don't reset workStart
            // either, since the user is still inside the "work session" we
            // already started.
            //
            // The first tick after launch has no `lastActivity` yet; seed it
            // so subsequent rest calculations have a reference point.
            if lastActivity == nil {
                lastActivity = now
            }
            lastEvent = .none
        }

        let elapsed = now.timeIntervalSince(workStart ?? now)
        if elapsed >= workThreshold {
            // Only fire the overtime event the tick we cross the threshold;
            // subsequent ticks while still over the threshold are "none"
            // so we don't spam the log.
            if lastEvent != .overtimeReached(elapsed: elapsed) {
                lastEvent = .overtimeReached(elapsed: elapsed)
            }
            return .overtime
        }
        return .working
    }

    /// Current work duration in seconds (0 if no session in progress).
    var workDuration: TimeInterval {
        guard let start = workStart else { return 0 }
        return max(0, Date().timeIntervalSince(start))
    }

    /// Work duration computed against an explicit "now" — for testing.
    func workDuration(at now: Date) -> TimeInterval {
        guard let start = workStart else { return 0 }
        return max(0, now.timeIntervalSince(start))
    }
}
