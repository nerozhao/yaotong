import Foundation

/// Single source of truth for the app version and build metadata.
/// Mirrors the keys in `Resources/Info.plist`; keep them in sync when
/// bumping.
enum AppVersion {
    /// `CFBundleShortVersionString` — user-facing "0.2.0" string.
    static let short: String = "0.2.0"
    /// `CFBundleVersion` — monotonically increasing build number.
    static let build: String = "2"

    /// ISO-8601 UTC timestamp written by `build.sh` on every build
    /// (custom `YTBuildTime` key in Info.plist). Falls back to
    /// "unknown" when running from `swift test`, where the bundle
    /// plist is the test runner's, not ours.
    static let buildTime: String = {
        Bundle.main.object(forInfoDictionaryKey: "YTBuildTime") as? String ?? "unknown"
    }()

    /// "0.2.0 (2)" — convenient for display.
    static let display: String = "\(short) (\(build))"

    /// "v0.2.0 (2) · built 2026-06-05T14:32:00Z" — the full footer line.
    static let footer: String = "v\(display) · built \(buildTime)"
}
