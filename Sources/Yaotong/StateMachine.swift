import Foundation

/// The icon state the menu bar can show.
enum StatusState: Equatable {
    case working
    case overtime
}

/// Reason the state machine's state changed on a given tick.
enum StateMachineEvent: Equatable {
    case none
    /// Work counter just went from 0 to 1 (after launch, pause, or rest-reset).
    case workSessionStarted
    /// Rest counter crossed the rest threshold, resetting the work counter.
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
            return "工作会话开始：计时器已归零"
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

/// State machine with **two independent counters** that run simultaneously:
///
/// - `workTime` counts up every tick. It is reset to 0 only when the user
///   "rests" (idle for `restThreshold` seconds).
/// - `restTime` counts up every tick *unless* the user is currently active
///   (mouse / keyboard input in the last second), in which case it resets
///   to 0.
///
/// The icon is `overtime` when `workTime >= workThreshold`, else `working`.
final class StateMachine {

    /// Time below which a tick is considered "the user is currently
    /// doing something". Anything longer is treated as "no input".
    static let activityThreshold: TimeInterval = 1.0

    private(set) var workTime: TimeInterval = 0
    private(set) var restTime: TimeInterval = 0
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
        if isPaused {
            workTime = 0
            restTime = 0
            lastEvent = .paused
            return .working
        }

        let wasActive = idleSeconds < Self.activityThreshold
        let prevWork = workTime
        let prevRest = restTime

        // Both counters tick up. The rest counter is re-zeroed on activity;
        // when not active, we just adopt the system's view of "how long has
        // the user been idle" — that way a long idle period is picked up
        // even if some ticks were coalesced or missed.
        workTime += 1
        if wasActive {
            restTime = 0
        } else {
            restTime = idleSeconds
        }

        // Rest crossed threshold → work resets to 0.
        if prevRest < restThreshold && restTime >= restThreshold {
            workTime = 0
            lastEvent = .workSessionReset(idleSeconds: restTime)
            return .working
        }

        // Work crossed threshold → overtime.
        if prevWork < workThreshold && workTime >= workThreshold {
            lastEvent = .overtimeReached(elapsed: workTime)
            return .overtime
        }

        // Work just started ticking (from 0 to 1) — either at launch,
        // after pause, or after a rest-reset.
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
        lastEvent = .none
    }
}
