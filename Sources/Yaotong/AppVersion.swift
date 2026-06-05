import Foundation

/// Single source of truth for the app version. Mirrors the
/// `CFBundleShortVersionString` / `CFBundleVersion` keys in
/// `Resources/Info.plist`; keep them in sync when bumping.
enum AppVersion {
    /// `CFBundleShortVersionString` — user-facing "0.2.0" string.
    static let short: String = "0.2.0"
    /// `CFBundleVersion` — monotonically increasing build number.
    static let build: String = "2"

    /// "0.2.0 (2)" — convenient for display.
    static let display: String = "\(short) (\(build))"
}
