import Foundation

/// Single source of truth for the app version and build metadata.
/// All three values (`short` / `build` / `buildTime`) are read live
/// from `Bundle.main.infoDictionary` — the `Resources/Info.plist`
/// file that `build.sh` substitutes into the bundle. Bumping the
/// keys there is enough; this file has no parallel constants to keep
/// in sync (the v0.3.6 release shipped with hardcoded values here
/// and the version check looped forever).
enum AppVersion {
    /// `CFBundleShortVersionString` — user-facing "0.3.7" string.
    /// Falls back to "0.0.0" outside the app bundle (e.g. `swift test`,
    /// where `Bundle.main` is the test runner and our plist isn't
    /// embedded). Tests don't consume this — `UpdateChecker.classify`
    /// always takes an explicit `currentVersion:` — so the fallback
    /// is unreachable in practice.
    static let short: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
    }()

    /// `CFBundleVersion` — monotonically increasing build number.
    /// Same fallback rule as `short`.
    static let build: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "0"
    }()

    /// ISO-8601 UTC timestamp written by `build.sh` on every build
    /// (custom `YTBuildTime` key in Info.plist). Falls back to
    /// "unknown" when running from `swift test`, where the bundle
    /// plist is the test runner's, not ours.
    static let buildTime: String = {
        Bundle.main.object(forInfoDictionaryKey: "YTBuildTime") as? String ?? "unknown"
    }()

    /// Build time reformatted in the system's local timezone. Falls
    /// back to the raw `buildTime` string if parsing fails (e.g.
    /// "unknown" during `swift test`). The Info.plist stores UTC;
    /// this shifts the stamp to whatever the user's machine is set
    /// to so the footer reads naturally without forcing UTC+8.
    static let localBuildTime: String = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: buildTime) else { return buildTime }
        let display = DateFormatter()
        // No explicit timezone set — defaults to `TimeZone.current`.
        display.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return display.string(from: date)
    }()

    /// "v0.3.7 · built 2026-06-09 17:30:00" — the footer line. The
    /// build number is intentionally omitted: the version is what
    /// users quote when reporting issues, the wall-clock is what they
    /// care about, and `(N)` adds no information once you know the date.
    static let footer: String = "v\(short) · built \(localBuildTime)"
}
