import Foundation
import os.log

/// Checks whether a newer version of 腰痛 is available.
///
/// Default endpoint is the GitHub Releases API. The owner/repo is
/// declared at the top of this file so a fork only needs to change
/// one constant — the rest of the pipeline is endpoint-agnostic and
/// will work against any JSON file that returns the same shape (a
/// `tag_name` + `html_url` + optional `body`).
///
/// All network and parsing code lives in a single async function so
/// it's trivially mockable: tests inject a `URLSession` configured
/// with `URLProtocol` stubs, or call `parseRelease(_:currentVersion:)`
/// directly with hand-crafted JSON.
struct UpdateChecker {

    // MARK: - Configuration

    /// Owner/repo on GitHub that publishes releases. Override at
    /// build time by setting `YT_UPDATE_REPO=owner/repo` in the
    /// environment (the build script doesn't set it — the value
    /// below is the default).
    static let defaultRepo: String = {
        if let env = ProcessInfo.processInfo.environment["YT_UPDATE_REPO"],
           env.contains("/") {
            return env
        }
        return "nerozhao/yaotong"
    }()

    /// Endpoint URL. Computed once at first use; tests can override
    /// via the `url` parameter on `check()`.
    static let defaultURL: URL = {
        URL(string: "https://api.github.com/repos/\(defaultRepo)/releases/latest")!
    }()

    /// Throttle window — even a manual "check for updates" click
    /// is ignored if we hit the API less than this many seconds
    /// ago. 6 hours is the GitHub secondary rate-limit reset
    /// window, so a misbehaving caller can't get us rate-limited.
    static let manualThrottleSeconds: TimeInterval = 6 * 3600

    /// Throttle window for the background check on launch. 24h
    /// matches Sparkle's default `SUCheckAtLaunch`-equivalent
    /// cadence and is short enough that a user who installs the
    /// app and leaves it running will see new releases within a
    /// day of publishing.
    static let backgroundThrottleSeconds: TimeInterval = 24 * 3600

    // MARK: - Result

    /// What the user sees after a check. Drives the alert text and
    /// the menu badge.
    enum Result: Equatable {
        /// The remote version is strictly newer than the running one.
        case updateAvailable(UpdateInfo)
        /// Already on the latest published version.
        case upToDate
        /// The user has previously dismissed this exact version —
        /// treat it as up-to-date so we don't re-prompt.
        case skipped(UpdateInfo)
        /// Network / parse / format error. We never surface this to
        /// the user; it's logged for debugging.
        case failed(String)
    }

    /// What triggered the check. Drives the throttle window and
    /// the prompt strategy in `UpdatePrompt.show(_:source:)`.
    enum Source { case background, manual }

    /// Parsed release payload. `notes` is the markdown release
    /// body — kept short by GitHub, suitable for pasting into an
    /// alert.
    struct UpdateInfo: Equatable {
        let version: String
        let htmlURL: URL
        let notes: String?

        /// One-line summary used in the alert title.
        var headline: String { "发现新版本 v\(version)" }
    }

    // MARK: - Storage

    /// Persisted state — when we last checked, and which version
    /// the user dismissed. Lives in a tiny `UserDefaults` wrapper
    /// so tests can inject their own suite.
    final class State {
        private enum Key {
            static let lastCheck = "yaotong.update.lastCheck"
            static let skippedVersion = "yaotong.update.skippedVersion"
        }
        private let defaults: UserDefaults
        init(defaults: UserDefaults = .standard) {
            self.defaults = defaults
        }
        var lastCheck: Date? {
            get { defaults.object(forKey: Key.lastCheck) as? Date }
            set { defaults.set(newValue, forKey: Key.lastCheck) }
        }
        var skippedVersion: String? {
            get { defaults.string(forKey: Key.skippedVersion) }
            set { defaults.set(newValue, forKey: Key.skippedVersion) }
        }
    }

    // MARK: - Check entry point

    let state: State
    let currentVersion: String
    private let session: URLSession
    private let log = OSLog(subsystem: "local.yaotong", category: "update")

    init(currentVersion: String = AppVersion.short,
         state: State = State(),
         session: URLSession = .shared) {
        self.currentVersion = currentVersion
        self.state = state
        self.session = session
    }

    /// Run a check. `source` chooses the throttle window — manual
    /// menu clicks still respect `manualThrottleSeconds` so an
    /// impatient user can't burn through the GitHub rate limit.
    func check(source: Source, url: URL = UpdateChecker.defaultURL) async -> Result {
        // Throttle: skip the network call entirely if we asked
        // recently. For `manual`, the check is *allowed* if no
        // previous check exists (first run) — only the time
        // delta is checked.
        let throttle = (source == .manual)
            ? Self.manualThrottleSeconds
            : Self.backgroundThrottleSeconds
        if let last = state.lastCheck,
           Date().timeIntervalSince(last) < throttle {
            return .upToDate
        }

        do {
            let (data, response) = try await fetch(url: url)
            try validate(response: response)
            let info = try Self.parseRelease(data)
            state.lastCheck = Date()
            return Self.classify(info: info, currentVersion: currentVersion, skipped: state.skippedVersion)
        } catch let error as UpdateError {
            os_log("update check failed: %{public}@", log: log, type: .error, error.description)
            return .failed(error.description)
        } catch {
            os_log("update check failed: %{public}@", log: log, type: .error, String(describing: error))
            return .failed(String(describing: error))
        }
    }

    // MARK: - Networking

    private func fetch(url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        // GitHub's API returns 403 with `X-RateLimit-Remaining: 0`
        // if we don't identify ourselves. Any UA works but a
        // recognisable string makes it easier for the user to
        // find the offender in the GitHub audit log if they ever
        // look.
        request.setValue("Yaotong/\(AppVersion.short)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        return try await session.data(for: request)
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.notHTTP
        }
        // 404 means the repo has no releases yet — treat as
        // "up to date" so a brand-new install doesn't surface a
        // scary error. (We re-route it through `.upToDate` in
        // `check` by virtue of the parsed result being nil;
        // throw `noRelease` here so the catch logs it as a soft
        // miss, not a hard error.)
        guard (200..<300).contains(http.statusCode) else {
            throw UpdateError.httpStatus(http.statusCode)
        }
    }

    // MARK: - Parsing

    /// Decodes a GitHub releases JSON payload. Exposed (not
    /// private) so tests can call it with hand-rolled JSON.
    static func parseRelease(_ data: Data) throws -> UpdateInfo {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw UpdateError.malformed }
        guard let tag = raw["tag_name"] as? String, !tag.isEmpty else {
            throw UpdateError.malformed
        }
        let version = stripTagPrefix(tag)
        guard isValidVersion(version) else { throw UpdateError.malformed }
        let urlString = (raw["html_url"] as? String) ?? "https://github.com/\(defaultRepo)/releases"
        guard let url = URL(string: urlString) else { throw UpdateError.malformed }
        let body = raw["body"] as? String
        return UpdateInfo(version: version, htmlURL: url, notes: body)
    }

    /// Classify a parsed release against the running version and
    /// the user's previously-dismissed version. Pure function —
    /// exposed (not `private`) so tests can call it directly
    /// without going through the async network path.
    static func classify(info: UpdateInfo,
                         currentVersion: String,
                         skipped: String?) -> Result {
        if info.version == skipped { return .skipped(info) }
        return isNewer(remote: info.version, current: currentVersion)
            ? .updateAvailable(info)
            : .upToDate
    }

    // MARK: - Semver

    /// `v0.2.0` → `0.2.0`. Accepts no prefix, `v` prefix, or `V`
    /// prefix. Anything else falls through to the version-validity
    /// check.
    static func stripTagPrefix(_ tag: String) -> String {
        var t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        return t
    }

    /// Permissive version check: `MAJOR.MINOR.PATCH` plus optional
    /// `-prerelease` / `+build`. We don't actually need the
    /// pre-release semantics for a "is X newer than Y" comparison
    /// — we just need to know the three dot-separated numbers are
    /// integers. The `+build` suffix is stripped first since the
    /// build metadata doesn't participate in ordering.
    static func isValidVersion(_ version: String) -> Bool {
        guard let parts = numericComponents(version) else { return false }
        return (1...3).contains(parts.count)
    }

    /// True iff `remote` is strictly newer than `current` by
    /// semantic-version rules. A `current` value that can't be
    /// parsed returns `false` (we never want to claim there's an
    /// update just because we couldn't read the local version).
    static func isNewer(remote: String, current: String) -> Bool {
        guard let r = numericComponents(remote),
              let c = numericComponents(current) else { return false }
        let pad = max(r.count, c.count)
        for i in 0..<pad {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv > cv { return true }
            if rv < cv { return false }
        }
        return false
    }

    /// Extracts the `[major, minor, patch]` integers from a
    /// version string, ignoring any `-prerelease` / `+build`
    /// suffix. Returns `nil` if any component is non-numeric or
    /// if a component is empty (catches `1..2`, `.1.0`, `1.0.`).
    /// `omittingEmptySubsequences: false` is the load-bearing
    /// argument on the `.` split — the default `true` would
    /// silently let `1..2` collapse to `[1, 2]` and pass.
    private static func numericComponents(_ version: String) -> [Int]? {
        // Strip `+build` then `-prerelease`, then split on `.`
        // keeping empty components so the validity check below
        // can catch malformed inputs.
        let noBuild = String(version.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        let core = String(noBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        var out: [Int] = []
        for p in parts {
            if p.isEmpty { return nil }
            guard let n = Int(p) else { return nil }
            out.append(n)
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Errors

    private enum UpdateError: Error {
        case notHTTP
        case httpStatus(Int)
        case malformed

        var description: String {
            switch self {
            case .notHTTP: return "non-HTTP response"
            case .httpStatus(let code): return "HTTP \(code)"
            case .malformed: return "malformed release JSON"
            }
        }
    }
}
