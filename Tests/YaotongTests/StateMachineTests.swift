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
}
