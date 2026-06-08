import Foundation

/// Single source of truth for the app version and build metadata.
/// Mirrors the keys in `Resources/Info.plist`; keep them in sync when
/// bumping.
enum AppVersion {
    /// `CFBundleShortVersionString` — user-facing "0.3.5" string.
    static let short: String = "0.3.5"
    /// `CFBundleVersion` — monotonically increasing build number.
    static let build: String = "8"

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

    /// "v0.3.5 · built 2026-06-08 09:45:00" — the footer line. The
    /// build number is intentionally omitted: the version is what
    /// users quote when reporting issues, the wall-clock is what they
    /// care about, and `(8)` adds no information once you know the date.
    static let footer: String = "v\(short) · built \(localBuildTime)"
}
