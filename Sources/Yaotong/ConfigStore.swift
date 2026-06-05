import Foundation
import Combine

/// User-facing, persisted settings for the 腰痛 app.
///
/// Wraps UserDefaults. All changes are observed via `onChange` (legacy
/// callback) and `@Published` properties (SwiftUI binding target).
final class ConfigStore: ObservableObject {

    // MARK: - Defaults

    static let defaultWorkMinutes = 31
    static let defaultRestMinutes = 11

    static let allowedMinuteOptions: [Int] = [6, 11, 16, 21, 31, 46, 61]

    static let pauseDuration: TimeInterval = 60 * 60  // 1 hour

    // MARK: - Keys

    private enum Key {
        static let workMinutes = "yaotong.workMinutes"
        static let restMinutes = "yaotong.restMinutes"
        static let pauseUntil = "yaotong.pauseUntil"
    }

    // MARK: - Storage

    private let defaults: UserDefaults
    private let suiteName: String?

    /// Last assignment to `workMinutes` / `restMinutes` / `pauseUntil`. Bumped
    /// on every change so SwiftUI views bound to the store can re-read.
    @Published private(set) var revision: Int = 0

    /// Fired whenever any setting changes. Receives the new ConfigStore.
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
            return Self.allowedMinuteOptions.contains(raw) ? raw : Self.defaultWorkMinutes
        }
        set {
            let value = Self.allowedMinuteOptions.contains(newValue) ? newValue : Self.defaultWorkMinutes
            defaults.set(value, forKey: Key.workMinutes)
            revision += 1
            onChange?(self)
        }
    }

    var restMinutes: Int {
        get {
            let raw = defaults.integer(forKey: Key.restMinutes)
            return Self.allowedMinuteOptions.contains(raw) ? raw : Self.defaultRestMinutes
        }
        set {
            let value = Self.allowedMinuteOptions.contains(newValue) ? newValue : Self.defaultRestMinutes
            defaults.set(value, forKey: Key.restMinutes)
            revision += 1
            onChange?(self)
        }
    }

    var workThreshold: TimeInterval { TimeInterval(workMinutes * 60) }
    var restThreshold: TimeInterval { TimeInterval(restMinutes * 60) }

    // MARK: - Pause

    /// Wall-clock time at which the pause ends. `nil` if not paused.
    var pauseUntil: Date? {
        get { defaults.object(forKey: Key.pauseUntil) as? Date }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.pauseUntil)
            } else {
                defaults.removeObject(forKey: Key.pauseUntil)
            }
            revision += 1
            onChange?(self)
        }
    }

    /// Returns `true` if the user is currently paused and the pause window
    /// has not yet expired.
    func isPaused(now: Date = Date()) -> Bool {
        guard let until = pauseUntil else { return false }
        return now < until
    }

    /// Toggle to start or end a pause. Returns the new pause state.
    @discardableResult
    func togglePause(now: Date = Date()) -> Bool {
        if isPaused(now: now) {
            pauseUntil = nil
            return false
        } else {
            pauseUntil = now.addingTimeInterval(Self.pauseDuration)
            return true
        }
    }
}
