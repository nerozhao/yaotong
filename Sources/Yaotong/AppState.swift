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

    /// Current work session length in seconds. Written by the tick loop
    /// every second; read by the debug panel's config tab.
    @Published var workDurationSeconds: TimeInterval = 0
    /// Work threshold in seconds (derived from `config.workMinutes`).
    /// The debug panel uses this to show "MM:SS / MM:SS" and a progress bar.
    @Published var workThresholdSeconds: TimeInterval = 0
    /// Current rest threshold in seconds, for display in the config tab.
    @Published var restThresholdSeconds: TimeInterval = 0

    func setForcedState(_ state: StatusState?) {
        forcedIconState = state
    }

    func clearForcedState() {
        forcedIconState = nil
    }
}
