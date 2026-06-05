import Foundation

/// The icon state the menu bar can show.
enum StatusState: Equatable {
    case working
    case overtime
}

/// Reason the state machine's state changed on a given tick.
enum StateMachineEvent: Equatable {
    case none
    /// Work counter just went from 0 to 1 — after a rest-reset, the
    /// user became active again and the post-rest gate released.
    case workSessionStarted
    /// Rest counter crossed the rest threshold, resetting the work
    /// counter and engaging the post-rest gate.
    /// `idleSeconds` is how long the user had been idle when we detected it.
    case workSessionReset(idleSeconds: TimeInterval)
    /// Work counter crossed the work threshold.
    /// `elapsed` is the current work-counter value in seconds.
    case overtimeReached(elapsed: TimeInterval)
    /// A tick happened while paused.
    case paused

    var logMessage: String {
        switch self {
        case .none:
            return ""
        case .workSessionStarted:
            return "工作会话开始：检测到活动，重置后恢复计时"
        case .workSessionReset(let idle):
            let mins = Int(idle / 60)
            let secs = Int(idle.truncatingRemainder(dividingBy: 60))
            return "休息判定：已空闲 \(mins)分\(secs)秒，重置工作计时器并等待活动"
        case .overtimeReached(let elapsed):
            let mins = Int(elapsed / 60)
            let secs = Int(elapsed.truncatingRemainder(dividingBy: 60))
            return "超时判定：已工作 \(mins)分\(secs)秒，达到工作阈值"
        case .paused:
            return "暂停中：跳过本次 tick"
        }
    }
}

/// State machine with two counters and a "post-rest gate":
///
/// - **`workTime`**: wall-clock time since the last "rested" event. It
///   ticks every second **unless** the post-rest gate is engaged, in
///   which case it stays at 0 until the user becomes active again.
///   It is reset to 0 when the rest threshold is hit, and the gate
///   is engaged at the same time.
///
/// - **`restTime`**: idle time since the last activity event. Resets
///   to 0 every time the user is active, otherwise adopts the
///   system-reported idle seconds.
///
/// The icon is `overtime` when `workTime >= workThreshold`, else `working`.
final class StateMachine {

    /// Time below which a tick is considered "the user is currently
    /// doing something". Anything longer is treated as "no input".
    static let activityThreshold: TimeInterval = 1.0

    private(set) var workTime: TimeInterval = 0
    private(set) var restTime: TimeInterval = 0
    /// True when work has been reset to 0 by a rest event and is waiting
    /// for the user to become active before resuming.
    private(set) var waitingForActivity: Bool = false
    private(set) var lastEvent: StateMachineEvent = .none

    let workThreshold: TimeInterval
    let restThreshold: TimeInterval

    init(workMinutes: Int, restMinutes: Int) {
        self.workThreshold = TimeInterval(workMinutes * 60)
        self.restThreshold = TimeInterval(restMinutes * 60)
    }

    /// Apply a tick. Returns the resulting state. After the call,
    /// `lastEvent` describes what happened (for the log).
    @discardableResult
    func tick(now: Date, idleSeconds: TimeInterval, isPaused: Bool) -> StatusState {
        if isPaused {
            workTime = 0
            restTime = 0
            waitingForActivity = false
            lastEvent = .paused
            return .working
        }

        let wasActive = idleSeconds < Self.activityThreshold
        let prevWork = workTime
        let prevRest = restTime

        // Rest counter: 0 when active, otherwise adopt the system's view.
        if wasActive {
            restTime = 0
        } else {
            restTime = idleSeconds
        }

        // Rest crossed threshold → reset work AND engage the post-rest gate.
        if prevRest < restThreshold && restTime >= restThreshold {
            workTime = 0
            waitingForActivity = true
            lastEvent = .workSessionReset(idleSeconds: restTime)
            return .working
        }

        // Activity releases the post-rest gate. Emit a "started" event
        // when work resumes after a gate.
        if wasActive && waitingForActivity {
            waitingForActivity = false
            // Don't increment workTime this tick — the user just
            // became active; the first real "1 second of work" lands
            // on the next tick.
            lastEvent = .workSessionStarted
            return .working
        }

        // Work counter: ticks every second unless the post-rest gate is
        // still engaged.
        guard !waitingForActivity else {
            lastEvent = .none
            return .working
        }
        workTime += 1

        // Work crossed the overtime threshold.
        if prevWork < workThreshold && workTime >= workThreshold {
            lastEvent = .overtimeReached(elapsed: workTime)
            return .overtime
        }

        // Work session just kicked off (0 → 1).
        if prevWork == 0 && workTime == 1 {
            lastEvent = .workSessionStarted
            return .working
        }

        lastEvent = .none
        return workTime >= workThreshold ? .overtime : .working
    }

    /// Reset both counters (e.g. on launch or when the work/rest
    /// thresholds change and we recreate the machine).
    func reset() {
        workTime = 0
        restTime = 0
        waitingForActivity = false
        lastEvent = .none
    }

    /// Treat a detected system sleep/wake event as a "rested" event.
    /// The user is presumed to have been away from the desk, so we
    /// reset the work counter and engage the post-rest gate — work
    /// only resumes after the next user input.
    func handleSleepWake() {
        workTime = 0
        restTime = 0
        waitingForActivity = true
        lastEvent = .workSessionReset(idleSeconds: 0)
    }
}
