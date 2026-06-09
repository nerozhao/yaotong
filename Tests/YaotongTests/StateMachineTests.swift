import XCTest
@testable import Yaotong

final class StateMachineTests: XCTestCase {

    // MARK: - Work accumulation

    func testActiveTicksAccumulateWorkTime() {
        let sm = StateMachine(workMinutes: 30, restMinutes: 10)
        var now = Date(timeIntervalSince1970: 0)

        // 29 minutes of activity, one tick per minute: still working.
        for _ in 0..<(29 * 60) {
            let state = sm.tick(now: now, idleSeconds: 0, isPaused: false)
            XCTAssertEqual(state, .working, "Should be working before the threshold")
            now.addTimeInterval(1)
        }

        // Push through the next 60 seconds — at the 30-minute mark, overtime.
        for _ in 0..<60 {
            _ = sm.tick(now: now, idleSeconds: 0, isPaused: false)
            now.addTimeInterval(1)
        }
        let after30min = sm.tick(now: now, idleSeconds: 0, isPaused: false)
        XCTAssertEqual(after30min, .overtime, "Should cross into overtime at the threshold")
    }

    func testNoActivityKeepsWorking() {
        let sm = StateMachine(workMinutes: 30, restMinutes: 10)
        let t0 = Date(timeIntervalSince1970: 0)
        // First tick: idle, but well under rest threshold. Seeds the state machine.
        let s1 = sm.tick(now: t0, idleSeconds: 5, isPaused: false)
        XCTAssertEqual(s1, .working)
    }

    // MARK: - Rest resets work

    func testRestingBeyondThresholdResetsWork() {
        let sm = StateMachine(workMinutes: 30, restMinutes: 10)
        let t0 = Date(timeIntervalSince1970: 0)
        // Work for 31 minutes — should be overtime.
        for i in 0..<(31 * 60) {
            _ = sm.tick(now: t0.addingTimeInterval(TimeInterval(i)), idleSeconds: 0, isPaused: false)
        }
        // After 10 minutes of rest, the work session is reset and the
        // post-rest gate is engaged: the icon goes blue (.rested) and
        // work stays at 0 until the user comes back. A later active
        // tick is what releases the gate and returns to .working —
        // covered by `testWorkWaitsForActivityAfterRest` below.
        let tAfter = t0.addingTimeInterval(31 * 60 + 11 * 60)
        let state = sm.tick(now: tAfter, idleSeconds: 11 * 60, isPaused: false)
        XCTAssertEqual(state, .rested)
        // Rest crossed threshold → work was reset to 0.
        XCTAssertEqual(sm.workTime, 0)
        XCTAssertTrue(sm.waitingForActivity)
    }

    // MARK: - Pause

    func testPauseFreezesState() {
        let sm = StateMachine(workMinutes: 30, restMinutes: 10)
        let t0 = Date(timeIntervalSince1970: 0)
        // Get into overtime first.
        for i in 0..<(31 * 60) {
            _ = sm.tick(now: t0.addingTimeInterval(TimeInterval(i)), idleSeconds: 0, isPaused: false)
        }
        XCTAssertEqual(sm.tick(now: t0, idleSeconds: 0, isPaused: true), .working)
        // Even after 10 hours of "pause", the next tick should still report working
        // and not have advanced any work session.
        let tLater = t0.addingTimeInterval(10 * 60 * 60)
        XCTAssertEqual(sm.tick(now: tLater, idleSeconds: 10 * 60 * 60, isPaused: true), .working)
        XCTAssertEqual(sm.workTime, 0)
        XCTAssertEqual(sm.restTime, 0)
    }

    func testUnpauseStartsFreshSession() {
        let sm = StateMachine(workMinutes: 30, restMinutes: 10)
        let t0 = Date(timeIntervalSince1970: 0)
        // Pause for 1 hour.
        _ = sm.tick(now: t0, idleSeconds: 0, isPaused: true)
        let tAfter = t0.addingTimeInterval(60 * 60)
        // First active tick after the pause: a brand-new work session, not overtime.
        XCTAssertEqual(sm.tick(now: tAfter, idleSeconds: 0, isPaused: false), .working)
    }

    // MARK: - Edge cases

    func testZeroIdleStartsImmediately() {
        let sm = StateMachine(workMinutes: 30, restMinutes: 10)
        let t0 = Date(timeIntervalSince1970: 0)
        // idle == 0 (active) on the very first tick — should start a session
        // and not go straight to overtime.
        let state = sm.tick(now: t0, idleSeconds: 0, isPaused: false)
        XCTAssertEqual(state, .working)
    }

    func testThresholdsAreConfigurable() {
        // 1-minute work, 5-minute rest.
        let sm = StateMachine(workMinutes: 1, restMinutes: 5)
        let t0 = Date(timeIntervalSince1970: 0)
        for i in 0..<60 {
            _ = sm.tick(now: t0.addingTimeInterval(TimeInterval(i)), idleSeconds: 0, isPaused: false)
        }
        XCTAssertEqual(sm.tick(now: t0.addingTimeInterval(61), idleSeconds: 0, isPaused: false), .overtime)
    }

    // MARK: - Sleep / wake

    /// `handleSleepWake()` resets the work counter and engages the
    /// post-rest gate, so work only resumes after the next active
    /// tick — same observable behavior as a "user rested long enough"
    /// event.
    func testHandleSleepWakeResetsAndEngagesGate() {
        let sm = StateMachine(workMinutes: 30, restMinutes: 10)
        let t0 = Date(timeIntervalSince1970: 0)
        // Work for 31 minutes to get into overtime.
        for i in 0..<(31 * 60) {
            _ = sm.tick(now: t0.addingTimeInterval(TimeInterval(i)), idleSeconds: 0, isPaused: false)
        }
        XCTAssertEqual(sm.workTime, 31 * 60)
        XCTAssertFalse(sm.waitingForActivity)

        sm.handleSleepWake()

        XCTAssertEqual(sm.workTime, 0, "Sleep should reset the work counter")
        XCTAssertEqual(sm.restTime, 0, "Sleep should reset the rest counter")
        XCTAssertTrue(sm.waitingForActivity, "Sleep should engage the post-rest gate")
        XCTAssertEqual(sm.lastEvent, .workSessionReset(idleSeconds: 0))
    }

    /// After a sleep/wake event, idle ticks must not advance work —
    /// the user has to actually press a key / move a mouse for the
    /// gate to release and a new work session to begin.
    func testWorkStaysZeroAfterSleepUntilActivity() {
        let sm = StateMachine(workMinutes: 30, restMinutes: 10)
        let t0 = Date(timeIntervalSince1970: 0)
        sm.handleSleepWake()
        // 5 minutes of idle ticks post-sleep: work stays at 0, and
        // the post-rest gate keeps the state at `.rested` (blue)
        // regardless of how long the user stays away. `.working`
        // only comes back once the user is active again.
        for i in 0..<(5 * 60) {
            let state = sm.tick(
                now: t0.addingTimeInterval(TimeInterval(i)),
                idleSeconds: TimeInterval(i + 1),
                isPaused: false
            )
            XCTAssertEqual(state, .rested)
            XCTAssertEqual(sm.workTime, 0)
            XCTAssertTrue(sm.waitingForActivity)
        }
        // First active tick — gate releases, work starts next tick.
        _ = sm.tick(
            now: t0.addingTimeInterval(TimeInterval(5 * 60)),
            idleSeconds: 0,
            isPaused: false
        )
        XCTAssertFalse(sm.waitingForActivity)
        _ = sm.tick(
            now: t0.addingTimeInterval(TimeInterval(5 * 60 + 1)),
            idleSeconds: 0,
            isPaused: false
        )
        XCTAssertEqual(sm.workTime, 1)
    }

    // MARK: - Events

    func testFirstActiveTickEmitsWorkSessionStarted() {
        let sm = StateMachine(workMinutes: 30, restMinutes: 10)
        let t0 = Date(timeIntervalSince1970: 0)
        // First tick: idle under rest threshold AND active (idle=0).
        let state = sm.tick(now: t0, idleSeconds: 0, isPaused: false)
        XCTAssertEqual(state, .working)
        XCTAssertEqual(sm.lastEvent, .workSessionStarted)
    }

    func testSubsequentActiveTicksEmitNoEvent() {
        let sm = StateMachine(workMinutes: 30, restMinutes: 10)
        let t0 = Date(timeIntervalSince1970: 0)
        _ = sm.tick(now: t0, idleSeconds: 0, isPaused: false)
        _ = sm.tick(now: t0.addingTimeInterval(1), idleSeconds: 0, isPaused: false)
        XCTAssertEqual(sm.lastEvent, .none)
    }

    func testRestingBeyondThresholdEmitsWorkSessionReset() {
        let sm = StateMachine(workMinutes: 30, restMinutes: 10)
        let t0 = Date(timeIntervalSince1970: 0)
        // Work for 31 minutes (1860 active ticks).
        for i in 0..<(31 * 60) {
            _ = sm.tick(now: t0.addingTimeInterval(TimeInterval(i)), idleSeconds: 0, isPaused: false)
        }
        // Now report 42 minutes of idle — crosses the 10-min rest
        // threshold. State is `.rested` (post-rest gate engaged), not
        // `.working` — `.working` only comes back once the user is
        // active again.
        let state = sm.tick(
            now: t0.addingTimeInterval(TimeInterval(31 * 60 + 42 * 60)),
            idleSeconds: 42 * 60,
            isPaused: false
        )
        XCTAssertEqual(state, .rested)
        XCTAssertEqual(sm.lastEvent, .workSessionReset(idleSeconds: 42 * 60))
    }

    func testOvertimeThresholdEmitsOvertimeReached() {
        let sm = StateMachine(workMinutes: 30, restMinutes: 10)
        let t0 = Date(timeIntervalSince1970: 0)
        // Run 30 minutes of activity. The 30*60-th tick crosses the threshold.
        for i in 0..<(30 * 60) {
            _ = sm.tick(now: t0.addingTimeInterval(TimeInterval(i)), idleSeconds: 0, isPaused: false)
        }
        // After 30*60 ticks, workTime has crossed to 1800 exactly on the last
        // tick — the overtimeReached event was emitted at that crossing.
        XCTAssertEqual(sm.lastEvent, .overtimeReached(elapsed: 30 * 60))
    }

    func testPausedTickEmitsPausedEvent() {
        let sm = StateMachine(workMinutes: 30, restMinutes: 10)
        let t0 = Date(timeIntervalSince1970: 0)
        let state = sm.tick(now: t0, idleSeconds: 0, isPaused: true)
        XCTAssertEqual(state, .working)
        XCTAssertEqual(sm.lastEvent, .paused)
    }

    func testEventLogMessages() {
        XCTAssertEqual(
            StateMachineEvent.workSessionStarted.logMessage,
            "工作会话开始：检测到活动，重置后恢复计时"
        )
        XCTAssertEqual(
            StateMachineEvent.workSessionReset(idleSeconds: 615).logMessage,
            "休息判定：已空闲 10分15秒，重置工作计时器并等待活动"
        )
        XCTAssertEqual(
            StateMachineEvent.overtimeReached(elapsed: 1825).logMessage,
            "超时判定：已工作 30分25秒，达到工作阈值"
        )
        XCTAssertEqual(StateMachineEvent.paused.logMessage, "暂停中：跳过本次 tick")
        XCTAssertEqual(StateMachineEvent.none.logMessage, "")
    }

    func testWorkTimeAdvancesWithTicks() {
        let sm = StateMachine(workMinutes: 30, restMinutes: 10)
        let t0 = Date(timeIntervalSince1970: 0)
        // Initially both counters are 0.
        XCTAssertEqual(sm.workTime, 0)
        XCTAssertEqual(sm.restTime, 0)
        _ = sm.tick(now: t0, idleSeconds: 0, isPaused: false)
        // After one active tick: workTime=1, restTime=0.
        XCTAssertEqual(sm.workTime, 1)
        XCTAssertEqual(sm.restTime, 0)
        // Second tick — user is now idle for 5 sec. workTime STILL
        // increments (wall-clock); restTime adopts the system's idle
        // reading.
        _ = sm.tick(now: t0.addingTimeInterval(1), idleSeconds: 5, isPaused: false)
        XCTAssertEqual(sm.workTime, 2)
        XCTAssertEqual(sm.restTime, 5)
    }

    /// After a rest reset, work stays at 0 and the post-rest gate
    /// is engaged. The gate releases on the next active tick; the
    /// tick AFTER that is the first one that increments work.
    func testWorkWaitsForActivityAfterRest() {
        let sm = StateMachine(workMinutes: 30, restMinutes: 10)
        let t0 = Date(timeIntervalSince1970: 0)
        // Active for 31 min — work crosses the threshold (overtime).
        for i in 0..<(31 * 60) {
            _ = sm.tick(now: t0.addingTimeInterval(TimeInterval(i)), idleSeconds: 0, isPaused: false)
        }
        XCTAssertEqual(sm.workTime, 31 * 60)
        // Now report 11 min idle — rest crosses the threshold, work resets,
        // and the post-rest gate is engaged (state goes to `.rested`).
        let after = sm.tick(
            now: t0.addingTimeInterval(TimeInterval(31 * 60 + 11 * 60)),
            idleSeconds: 11 * 60,
            isPaused: false
        )
        XCTAssertEqual(after, .rested)
        XCTAssertEqual(sm.workTime, 0)
        XCTAssertTrue(sm.waitingForActivity)
        // More idle ticks — work stays at 0 and the gate keeps the
        // state at `.rested`. `.working` only comes back once the
        // user is active again.
        let stillIdle = sm.tick(
            now: t0.addingTimeInterval(TimeInterval(31 * 60 + 12 * 60)),
            idleSeconds: 12 * 60,
            isPaused: false
        )
        XCTAssertEqual(stillIdle, .rested)
        XCTAssertEqual(sm.workTime, 0)
        XCTAssertTrue(sm.waitingForActivity)
        // First active tick — gate releases, work stays at 0 (this is
        // the "I just noticed you" tick, not a full second of work).
        let firstActive = sm.tick(
            now: t0.addingTimeInterval(TimeInterval(31 * 60 + 13 * 60)),
            idleSeconds: 0,
            isPaused: false
        )
        XCTAssertEqual(firstActive, .working)
        XCTAssertEqual(sm.workTime, 0)
        XCTAssertFalse(sm.waitingForActivity)
        XCTAssertEqual(sm.lastEvent, .workSessionStarted)
        // Next active tick — work starts counting.
        _ = sm.tick(
            now: t0.addingTimeInterval(TimeInterval(31 * 60 + 14 * 60)),
            idleSeconds: 0,
            isPaused: false
        )
        XCTAssertEqual(sm.workTime, 1)
    }

    // MARK: - Manual reset (重置计时器 button)

    /// The "重置计时器" button drops both counters to 0 and does NOT
    /// engage the post-rest gate — the user is at the keyboard when
    /// they click, so the next tick should start accumulating work
    /// immediately. This is the key difference from `handleSleepWake`.
    func testStartFreshSessionResetsCounters() {
        let sm = StateMachine(workMinutes: 30, restMinutes: 10)
        let t0 = Date(timeIntervalSince1970: 0)
        // Get into a "deep work" state: 20 min active, then 5 min idle
        // (below rest threshold, so no gate engagement).
        for i in 0..<(20 * 60) {
            _ = sm.tick(now: t0.addingTimeInterval(TimeInterval(i)), idleSeconds: 0, isPaused: false)
        }
        for i in 0..<(5 * 60) {
            _ = sm.tick(
                now: t0.addingTimeInterval(TimeInterval(20 * 60 + i)),
                idleSeconds: TimeInterval(i + 1),
                isPaused: false
            )
        }
        XCTAssertEqual(sm.workTime, 25 * 60)
        XCTAssertEqual(sm.restTime, 5 * 60)
        XCTAssertFalse(sm.waitingForActivity)

        // User clicks the reset button.
        sm.startFreshSession()

        XCTAssertEqual(sm.workTime, 0)
        XCTAssertEqual(sm.restTime, 0)
        // Gate must NOT be engaged — the user is at the keyboard.
        XCTAssertFalse(sm.waitingForActivity)
        // No event emitted by the reset itself; the next active tick
        // will naturally fire `workSessionStarted` on the 0 → 1
        // transition.
        XCTAssertEqual(sm.lastEvent, .none)
    }

    /// After `startFreshSession`, the next active tick begins
    /// accumulating workTime immediately — no wait-for-activity gap.
    /// This is the whole point of the button: the user is saying
    /// "I'm working now", so the wall clock starts at 0 right away.
    func testStartFreshSessionStartsWorkOnNextTick() {
        let sm = StateMachine(workMinutes: 30, restMinutes: 10)
        let t0 = Date(timeIntervalSince1970: 0)
        // Get into overtime first so the reset has something to clear.
        for i in 0..<(31 * 60) {
            _ = sm.tick(now: t0.addingTimeInterval(TimeInterval(i)), idleSeconds: 0, isPaused: false)
        }
        XCTAssertEqual(sm.workTime, 31 * 60)

        sm.startFreshSession()
        XCTAssertEqual(sm.workTime, 0)

        // First active tick after reset: workTime is 0, state is
        // .working, no gate.
        let t1 = t0.addingTimeInterval(31 * 60)
        let s1 = sm.tick(now: t1, idleSeconds: 0, isPaused: false)
        XCTAssertEqual(s1, .working)
        XCTAssertEqual(sm.workTime, 1)
        XCTAssertEqual(sm.lastEvent, .workSessionStarted)
    }

    /// `startFreshSession` from inside a `waitingForActivity` gate
    /// must release the gate. This is the rescue path: the user has
    /// been idle long enough that rest reset fired, the icon is blue,
    /// they come back and click the button — now they want to work,
    /// not wait for the system's "next input" heuristic.
    func testStartFreshSessionReleasesPostRestGate() {
        let sm = StateMachine(workMinutes: 30, restMinutes: 10)
        let t0 = Date(timeIntervalSince1970: 0)
        // Work, then rest long enough to engage the gate.
        for i in 0..<(31 * 60) {
            _ = sm.tick(now: t0.addingTimeInterval(TimeInterval(i)), idleSeconds: 0, isPaused: false)
        }
        let after = sm.tick(
            now: t0.addingTimeInterval(TimeInterval(31 * 60 + 11 * 60)),
            idleSeconds: 11 * 60,
            isPaused: false
        )
        XCTAssertEqual(after, .rested)
        XCTAssertTrue(sm.waitingForActivity)

        // User clicks reset.
        sm.startFreshSession()
        XCTAssertFalse(sm.waitingForActivity)
        XCTAssertEqual(sm.workTime, 0)

        // Next active tick — work begins, no wait-for-activity gap.
        let t1 = t0.addingTimeInterval(TimeInterval(31 * 60 + 12 * 60))
        let s1 = sm.tick(now: t1, idleSeconds: 0, isPaused: false)
        XCTAssertEqual(s1, .working)
        XCTAssertEqual(sm.workTime, 1)
    }
}
