import Foundation
import UserNotifications
import os.log

/// Posts macOS user notifications when the work timer crosses its
/// threshold, and clears the delivered banner when the rest timer
/// crosses its threshold. The notifier is the only place that touches
/// `UNUserNotificationCenter` — the state machine stays a pure function,
/// and `AppDelegate.tick()` maps the two state-machine events to
/// `notifyOvertime` / `clearDelivered`.
///
/// Authorization is requested on first launch via
/// `requestAuthorizationIfNeeded()`. Until the user grants permission
/// all calls are silent no-ops.
///
/// `@MainActor`-isolated: the app's tick loop is the only caller, and
/// it runs on the main thread.
@MainActor
final class Notifier {

    /// Identifier reused for every overtime notification. A new
    /// request with the same identifier replaces the old one, so a
    /// long overtime session doesn't stack up identical banners.
    private static let overtimeNotificationIdentifier = "yaotong.overtime"

    private let log = OSLog(subsystem: "local.yaotong", category: "activity")

    /// Test escape hatch. `UNUserNotificationCenter.current()` crashes
    /// the process with `NSInternalInconsistencyException` when there
    /// is no app bundle (the SwiftPM test binary under `swift test`),
    /// so tests set this to `true` in `setUp` to short-circuit every
    /// call site that would otherwise touch the center. Production
    /// never sets it.
    static var testBypassCenter: Bool = false

    /// Lazily-initialized notification center. Only accessed when
    /// `testBypassCenter` is `false`. Kept lazy (rather than eagerly
    /// constructed in `init`) so a Notifier instance can be created
    /// in a test process without crashing the dispatch_once inside
    /// `currentNotificationCenter`.
    private lazy var center: UNUserNotificationCenter = {
        UNUserNotificationCenter.current()
    }()

    // MARK: - Test inspection
    //
    // The static counters below are how tests verify behavior
    // without spinning up a real `UNUserNotificationCenter` (which
    // prompts for permission and needs the notification daemon to
    // be running). Tests should reset them in `setUp`.

    static var notifyOvertimeCallCount: Int = 0
    static var clearDeliveredCallCount: Int = 0
    static var lastNotifiedElapsedSeconds: TimeInterval = 0
    static var didRequestAuthorization: Bool = false

    // MARK: - Authorization

    /// Request notification permission. Safe to call on every launch —
    /// the system only prompts the user once. Until permission is
    /// granted, all subsequent calls become silent no-ops.
    func requestAuthorizationIfNeeded() {
        Self.didRequestAuthorization = true
        guard !Self.testBypassCenter else { return }
        // Capture `center` and `log` locally so the background
        // callback doesn't need to re-enter the @MainActor-isolated
        // `self` to read them.
        let center = self.center
        let log = self.log
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        os_log("notification authorization error: %{public}@",
                               log: log, type: .error,
                               String(describing: error))
                    }
                    os_log("notification authorization result: granted=%{public}d",
                           log: log, type: .default,
                           granted ? 1 : 0)
                }
            default:
                break
            }
        }
    }

    // MARK: - Side effects

    /// Fire the work-threshold notification. Called from
    /// `AppDelegate.tick()` on `overtimeReached`. Clears any
    /// previously delivered notification first so the notification
    /// center never accumulates duplicates from re-fired overtime
    /// events.
    func notifyOvertime(elapsed: TimeInterval) {
        Self.notifyOvertimeCallCount += 1
        Self.lastNotifiedElapsedSeconds = elapsed

        guard !Self.testBypassCenter else { return }

        // Clear before push — keeps the notification center at
        // most one overtime entry, regardless of how many times
        // the state machine re-enters overtime.
        center.removeAllDeliveredNotifications()

        let mins = Int(elapsed / 60)
        let secs = Int(elapsed.truncatingRemainder(dividingBy: 60))
        let content = UNMutableNotificationContent()
        content.title = "腰痛提醒"
        content.body = "已经工作了 \(mins)分\(secs)秒，起身活动一下吧。"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: Self.overtimeNotificationIdentifier,
            content: content,
            trigger: nil  // deliver immediately
        )
        // Capture the locals so the background completion handler
        // doesn't re-enter `self` (which is @MainActor-isolated).
        let center = self.center
        let log = self.log
        center.add(request) { error in
            if let error {
                os_log("overtime notification delivery error: %{public}@",
                       log: log, type: .error,
                       String(describing: error))
            }
        }
    }

    /// Clear any delivered notifications. Called from
    /// `AppDelegate.tick()` on `workSessionReset` — when the user has
    /// rested long enough that the work counter resets, the
    /// "you've been working too long" banner is no longer relevant.
    func clearDelivered() {
        Self.clearDeliveredCallCount += 1
        guard !Self.testBypassCenter else { return }
        let center = self.center
        center.removeAllDeliveredNotifications()
    }
}
