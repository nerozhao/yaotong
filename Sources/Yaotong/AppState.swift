import Foundation
import Combine

/// Shared, mutable state that the debug panel writes to and the tick loop
/// reads from. Wraps things that are awkward to expose via `ConfigStore` or
/// `StateMachine` directly — currently just an "icon state override" so
/// the user can force the icon to white/red from the test tab.
@MainActor
final class AppState: ObservableObject {

    /// When non-nil, the tick loop uses this value instead of computing
    /// from the state machine. `nil` means "let the state machine decide".
    @Published var forcedIconState: StatusState?

    /// Current work-counter value in seconds. Updated by the tick loop.
    @Published var workDurationSeconds: TimeInterval = 0
    /// Current rest-counter value in seconds. Updated by the tick loop.
    @Published var restDurationSeconds: TimeInterval = 0
    /// Work threshold in seconds (derived from `config.workMinutes`).
    @Published var workThresholdSeconds: TimeInterval = 0
    /// Rest threshold in seconds (derived from `config.restMinutes`).
    @Published var restThresholdSeconds: TimeInterval = 0

    func setForcedState(_ state: StatusState?) {
        forcedIconState = state
    }

    func clearForcedState() {
        forcedIconState = nil
    }
}
