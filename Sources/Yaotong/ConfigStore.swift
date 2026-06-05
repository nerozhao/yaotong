import Foundation
import Combine

/// User-facing, persisted settings for the 腰痛 app.
///
/// Wraps UserDefaults. All changes are observed via `onChange` (legacy
/// callback) and `@Published` properties (SwiftUI binding target).
final class ConfigStore: ObservableObject {

    // MARK: - Defaults

    static let defaultWorkMinutes = 30
    static let defaultRestMinutes = 10

    /// Options for the work threshold. Min 2 minutes so the user has
    /// *some* time before the icon flips, and 1 minute would be too
    /// twitchy to be useful.
    static let allowedWorkMinuteOptions: [Int] = [2, 5, 10, 15, 20, 30, 45, 60]

    /// Options for the rest threshold. Min 1 minute so the user can
    /// quickly test the "rest" path without waiting 10 minutes.
    static let allowedRestMinuteOptions: [Int] = [1, 2, 5, 10, 15, 20, 30, 45, 60]

    // MARK: - Keys

    private enum Key {
        static let workMinutes = "yaotong.workMinutes"
        static let restMinutes = "yaotong.restMinutes"
    }

    // MARK: - Storage

    private let defaults: UserDefaults
    private let suiteName: String?

    /// Last assignment to `workMinutes` / `restMinutes`. Bumped
    /// on every change so SwiftUI views bound to the store can
    /// re-read.
    @Published private(set) var revision: Int = 0

    /// Fired whenever a setting changes. Receives the new ConfigStore.
    var onChange: ((ConfigStore) -> Void)?

    init(defaults: UserDefaults = .standard, suiteName: String? = nil) {
        self.defaults = defaults
        self.suiteName = suiteName
        registerDefaults()
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Key.workMinutes: Self.defaultWorkMinutes,
            Key.restMinutes: Self.defaultRestMinutes
        ])
    }

    // MARK: - Work / rest duration (minutes)

    var workMinutes: Int {
        get {
            let raw = defaults.integer(forKey: Key.workMinutes)
            return Self.allowedWorkMinuteOptions.contains(raw) ? raw : Self.defaultWorkMinutes
        }
        set {
            let value = Self.allowedWorkMinuteOptions.contains(newValue) ? newValue : Self.defaultWorkMinutes
            defaults.set(value, forKey: Key.workMinutes)
            revision += 1
            onChange?(self)
        }
    }

    var restMinutes: Int {
        get {
            let raw = defaults.integer(forKey: Key.restMinutes)
            return Self.allowedRestMinuteOptions.contains(raw) ? raw : Self.defaultRestMinutes
        }
        set {
            let value = Self.allowedRestMinuteOptions.contains(newValue) ? newValue : Self.defaultRestMinutes
            defaults.set(value, forKey: Key.restMinutes)
            revision += 1
            onChange?(self)
        }
    }

    var workThreshold: TimeInterval { TimeInterval(workMinutes * 60) }
    var restThreshold: TimeInterval { TimeInterval(restMinutes * 60) }

    // MARK: - Pause (manual toggle, in-memory only)

    /// True while the user has manually paused the monitor. A pure
    /// toggle — no time limit, no auto-resume.
    ///
    /// **Not persisted**: every app launch starts with `isPaused = false`
    /// (i.e. running). The pause state is for the current session only;
    /// we don't want yesterday's "I paused for a meeting" to still be
    /// active when the user starts the app today.
    var isPaused: Bool {
        get { _runtimeIsPaused }
        set {
            _runtimeIsPaused = newValue
            revision += 1
            onChange?(self)
        }
    }

    /// In-memory pause flag. Never written to UserDefaults.
    private var _runtimeIsPaused: Bool = false

    /// Flip the pause state. Returns the new value.
    @discardableResult
    func togglePause() -> Bool {
        isPaused.toggle()
        return isPaused
    }
}
