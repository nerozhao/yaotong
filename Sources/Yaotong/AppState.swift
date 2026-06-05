import Foundation
import Combine

/// Live values the SwiftUI main view displays. Updated once per tick
/// from the state machine; the two thresholds change only when the user
/// adjusts a setting.
@MainActor
final class AppState: ObservableObject {
    @Published var workDurationSeconds: TimeInterval = 0
    @Published var restDurationSeconds: TimeInterval = 0
    @Published var workThresholdSeconds: TimeInterval = 0
    @Published var restThresholdSeconds: TimeInterval = 0
}
