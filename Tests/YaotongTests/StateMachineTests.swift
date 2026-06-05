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
        // After 10 minutes of rest, the work session must be reset and we
        // must be back in .working.
        let tAfter = t0.addingTimeInterval(31 * 60 + 11 * 60)
        let state = sm.tick(now: tAfter, idleSeconds: 11 * 60, isPaused: false)
        XCTAssertEqual(state, .working)
        // Rest crossed threshold → work was reset to 0.
        XCTAssertEqual(sm.workTime, 0)
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
        // Now report 42 minutes of idle — crosses the 10-min rest threshold.
        let state = sm.tick(
            now: t0.addingTimeInterval(TimeInterval(31 * 60 + 42 * 60)),
            idleSeconds: 42 * 60,
            isPaused: false
        )
        XCTAssertEqual(state, .working)
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
            "工作会话开始：检测到活动"
        )
        XCTAssertEqual(
            StateMachineEvent.workSessionReset(idleSeconds: 615).logMessage,
            "休息判定：已空闲 10分15秒，重置工作计时器"
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
        // Second tick — user is now idle for 5 sec. workTime does NOT
        // increment (only counts while active); restTime adopts the
        // system's idle reading.
        _ = sm.tick(now: t0.addingTimeInterval(1), idleSeconds: 5, isPaused: false)
        XCTAssertEqual(sm.workTime, 1)
        XCTAssertEqual(sm.restTime, 5)
    }

    /// In the new model, work only counts during activity. If the user is
    /// idle for the entire rest threshold, work resets to 0 AND stays
    /// there until the next active tick.
    func testWorkStaysZeroAfterRestUntilActivity() {
        let sm = StateMachine(workMinutes: 30, restMinutes: 10)
        let t0 = Date(timeIntervalSince1970: 0)
        // Active for 31 min — work crosses the threshold (and is overtime).
        for i in 0..<(31 * 60) {
            _ = sm.tick(now: t0.addingTimeInterval(TimeInterval(i)), idleSeconds: 0, isPaused: false)
        }
        XCTAssertEqual(sm.workTime, 31 * 60)
        // Now report 11 min idle — rest crosses the threshold and work resets.
        let after = sm.tick(
            now: t0.addingTimeInterval(TimeInterval(31 * 60 + 11 * 60)),
            idleSeconds: 11 * 60,
            isPaused: false
        )
        XCTAssertEqual(after, .working)
        XCTAssertEqual(sm.workTime, 0)
        // Subsequent idle ticks — work must stay at 0.
        let stillIdle = sm.tick(
            now: t0.addingTimeInterval(TimeInterval(31 * 60 + 12 * 60)),
            idleSeconds: 12 * 60,
            isPaused: false
        )
        XCTAssertEqual(stillIdle, .working)
        XCTAssertEqual(sm.workTime, 0)
        // First active tick after the rest — work starts again.
        let activeAgain = sm.tick(
            now: t0.addingTimeInterval(TimeInterval(31 * 60 + 13 * 60)),
            idleSeconds: 0,
            isPaused: false
        )
        XCTAssertEqual(activeAgain, .working)
        XCTAssertEqual(sm.workTime, 1)
    }
}
