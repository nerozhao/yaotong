import Foundation

/// The icon state the menu bar can show.
enum StatusState: Equatable {
    /// User is working (or resting) and has not yet hit the work threshold.
    case working
    /// User has worked continuously past the work threshold.
    case overtime
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
///   - `state`: working vs overtime
///   - `workDuration`: how long the current work session has lasted (0 if
///     the user is currently resting, i.e. workStart is nil)
final class StateMachine {

    /// Time below which a tick is considered "the user is actively doing
    /// something right now". Anything longer is treated as "no input".
    static let activityThreshold: TimeInterval = 1.0

    private(set) var workStart: Date?
    private(set) var lastActivity: Date?

    let workThreshold: TimeInterval
    let restThreshold: TimeInterval

    init(workMinutes: Int, restMinutes: Int) {
        self.workThreshold = TimeInterval(workMinutes * 60)
        self.restThreshold = TimeInterval(restMinutes * 60)
    }

    /// Apply a tick. Returns the resulting state.
    @discardableResult
    func tick(now: Date, idleSeconds: TimeInterval, isPaused: Bool) -> StatusState {
        // While paused, never advance the timer. We also forget any in-flight
        // work session so a long pause followed by a return to work starts
        // fresh — matches the spec: "暂停期间不计时".
        if isPaused {
            workStart = nil
            lastActivity = nil
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
            return .working
        }

        // Is the user "active" this very second? If so, mark them active and
        // (re)start the work session if needed.
        if idleSeconds < Self.activityThreshold {
            lastActivity = now
            if workStart == nil {
                workStart = now
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
        }

        let elapsed = now.timeIntervalSince(workStart ?? now)
        return elapsed >= workThreshold ? .overtime : .working
    }

    /// Current work duration in seconds (0 if no session in progress).
    var workDuration: TimeInterval {
        guard let start = workStart else { return 0 }
        return max(0, Date().timeIntervalSince(start))
    }
}
