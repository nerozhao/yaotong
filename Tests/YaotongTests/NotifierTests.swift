import XCTest
@testable import Yaotong

@MainActor
final class NotifierTests: XCTestCase {

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        // Reset the static test counters — each test starts from a
        // known baseline. Tests run sequentially within a class, so
        // global state is safe to use here.
        Notifier.notifyOvertimeCallCount = 0
        Notifier.clearDeliveredCallCount = 0
        Notifier.lastNotifiedElapsedSeconds = 0
        Notifier.didRequestAuthorization = false
        // Bypass the real `UNUserNotificationCenter` — the SwiftPM
        // test binary has no app bundle, so `current()` would crash
        // with `NSInternalInconsistencyException`. Production never
        // sets this flag.
        Notifier.testBypassCenter = true
    }

    override func tearDown() {
        Notifier.testBypassCenter = false
        super.tearDown()
    }

    // MARK: - Authorization

    func testRequestAuthorizationIfNeededSetsFlag() {
        let notifier = Notifier()
        XCTAssertFalse(Notifier.didRequestAuthorization)
        notifier.requestAuthorizationIfNeeded()
        XCTAssertTrue(Notifier.didRequestAuthorization)
    }

    // MARK: - Overtime notification

    func testNotifyOvertimeIncrementsCounter() {
        let notifier = Notifier()
        notifier.notifyOvertime(elapsed: 30 * 60)
        XCTAssertEqual(Notifier.notifyOvertimeCallCount, 1)
        XCTAssertEqual(Notifier.lastNotifiedElapsedSeconds, 30 * 60)
    }

    func testNotifyOvertimeRecordsLatestElapsed() {
        let notifier = Notifier()
        notifier.notifyOvertime(elapsed: 30 * 60)
        notifier.notifyOvertime(elapsed: 31 * 60)
        XCTAssertEqual(Notifier.notifyOvertimeCallCount, 2)
        // `lastNotifiedElapsedSeconds` reflects the most recent call,
        // not the largest — useful for debugging "what value was
        // passed in last".
        XCTAssertEqual(Notifier.lastNotifiedElapsedSeconds, 31 * 60)
    }

    // MARK: - Clear delivered

    func testClearDeliveredIncrementsCounter() {
        let notifier = Notifier()
        notifier.clearDelivered()
        XCTAssertEqual(Notifier.clearDeliveredCallCount, 1)
        notifier.clearDelivered()
        XCTAssertEqual(Notifier.clearDeliveredCallCount, 2)
    }

    // MARK: - State machine integration

    /// Driving the state machine to the work threshold and
    /// dispatching the resulting `overtimeReached` event into the
    /// notifier should fire exactly one overtime notification.
    /// This mirrors the `overtimeReached` branch in
    /// `AppDelegate.tick()`. The notifier does NOT auto-clear —
    /// `clearDelivered` is only called on `workSessionReset`.
    func testOvertimeEventWiresToNotifier() {
        let notifier = Notifier()
        let sm = StateMachine(workMinutes: 30, restMinutes: 10)
        let t0 = Date(timeIntervalSince1970: 0)

        // 30 minutes of active ticks — the 30*60-th tick crosses
        // the work threshold and fires `overtimeReached`.
        for i in 0..<(30 * 60) {
            _ = sm.tick(
                now: t0.addingTimeInterval(TimeInterval(i)),
                idleSeconds: 0,
                isPaused: false
            )
        }
        XCTAssertEqual(sm.lastEvent, .overtimeReached(elapsed: 30 * 60))

        // Mirror the switch in AppDelegate.tick() — production
        // calls `notifyOvertime(elapsed:)` with no further args.
        if case .overtimeReached(let elapsed) = sm.lastEvent {
            notifier.notifyOvertime(elapsed: elapsed)
        }
        XCTAssertEqual(Notifier.notifyOvertimeCallCount, 1)
        XCTAssertEqual(Notifier.lastNotifiedElapsedSeconds, 30 * 60)
        // No auto-clear: the notification stays delivered until
        // `clearDelivered` is called by something else.
        XCTAssertEqual(Notifier.clearDeliveredCallCount, 0)
    }

    /// Driving the state machine past the rest threshold and
    /// dispatching the resulting `workSessionReset` event through
    /// the `AppDelegate.tick()` switch must call `clearDelivered`
    /// — the rest-reset is the only path that clears the
    /// delivered notification (the overtime notification
    /// auto-clears on its own 60 s timer).
    func testResetEventWiresToClearDelivered() {
        let notifier = Notifier()
        let sm = StateMachine(workMinutes: 30, restMinutes: 10)
        let t0 = Date(timeIntervalSince1970: 0)

        // 31 minutes of active work to get into overtime.
        for i in 0..<(31 * 60) {
            _ = sm.tick(
                now: t0.addingTimeInterval(TimeInterval(i)),
                idleSeconds: 0,
                isPaused: false
            )
        }
        // 11 minutes of idle — crosses the 10-min rest threshold
        // and fires `workSessionReset`.
        let after = sm.tick(
            now: t0.addingTimeInterval(TimeInterval(31 * 60 + 11 * 60)),
            idleSeconds: 11 * 60,
            isPaused: false
        )
        XCTAssertEqual(after, .rested)
        XCTAssertEqual(sm.lastEvent, .workSessionReset(idleSeconds: 11 * 60))

        // Mirror the switch in AppDelegate.tick() — the
        // workSessionReset case calls `clearDelivered`.
        switch sm.lastEvent {
        case .workSessionReset:
            notifier.clearDelivered()
        default:
            break
        }
        XCTAssertEqual(Notifier.clearDeliveredCallCount, 1)
    }
}
