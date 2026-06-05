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
        XCTAssertEqual(sm.workStart, nil)
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
        XCTAssertEqual(sm.workStart, nil)
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
        // Work for 31 minutes to get into overtime. The last active tick is
        // at i=1859 (loop runs 0..<1860).
        for i in 0..<(31 * 60) {
            _ = sm.tick(now: t0.addingTimeInterval(TimeInterval(i)), idleSeconds: 0, isPaused: false)
        }
        // Tick at t=2520 (11 min later); idle for 12 min vs. lastActivity at
        // t=1859, so sinceActivity = 661s.
        let tickAt: TimeInterval = 31 * 60 + 11 * 60
        let state = sm.tick(
            now: t0.addingTimeInterval(tickAt),
            idleSeconds: tickAt,
            isPaused: false
        )
        XCTAssertEqual(state, .working)
        XCTAssertEqual(sm.lastEvent, .workSessionReset(idleSeconds: 661))
    }

    func testOvertimeThresholdEmitsOvertimeReached() {
        let sm = StateMachine(workMinutes: 30, restMinutes: 10)
        let t0 = Date(timeIntervalSince1970: 0)
        // Cross the 30-minute threshold.
        for i in 0..<(30 * 60) {
            _ = sm.tick(now: t0.addingTimeInterval(TimeInterval(i)), idleSeconds: 0, isPaused: false)
        }
        let state = sm.tick(
            now: t0.addingTimeInterval(TimeInterval(30 * 60)),
            idleSeconds: 0,
            isPaused: false
        )
        XCTAssertEqual(state, .overtime)
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

    func testWorkDurationAt() {
        let sm = StateMachine(workMinutes: 30, restMinutes: 10)
        let t0 = Date(timeIntervalSince1970: 0)
        // No session yet — duration is 0.
        XCTAssertEqual(sm.workDuration(at: t0), 0)
        _ = sm.tick(now: t0, idleSeconds: 0, isPaused: false)
        // After a tick, the session started; duration matches the elapsed time.
        XCTAssertEqual(sm.workDuration(at: t0.addingTimeInterval(120)), 120)
    }
}
