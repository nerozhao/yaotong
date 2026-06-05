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

    func setForcedState(_ state: StatusState?) {
        forcedIconState = state
    }

    func clearForcedState() {
        forcedIconState = nil
    }
}
