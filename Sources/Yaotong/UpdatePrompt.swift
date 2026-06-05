import AppKit
import os.log

/// Renders the result of an `UpdateChecker.check` as a user-facing
/// `NSAlert`. Kept separate from the checker itself so the network
/// code stays testable and the UI code can be swapped (SwiftUI
/// sheet, banner, …) without touching parsing/semver logic.
///
/// The alert is *informational* for the `upToDate` and
/// `skipped` cases, and *actionable* for `updateAvailable`. The
/// `failed` case is silent on background checks (logged via
/// `os_log`) and shows a small error dialog on manual checks —
/// the user explicitly asked to know the result, so silent
/// failure is the wrong UX there.
@MainActor
enum UpdatePrompt {

    private static let log = OSLog(subsystem: "local.yaotong", category: "update")

    /// Show the alert for this result, given the source that
    /// triggered the check. The "should we even prompt?" decision
    /// lives in `shouldShow` so the show and the tests can share
    /// one source of truth. Background checks are silent unless
    /// an update is actually available — the user does not want
    /// to be told "no update" on every launch. Manual checks
    /// surface every outcome so the user can tell the click
    /// registered and the check completed.
    @discardableResult
    static func show(_ result: UpdateChecker.Result, source: UpdateChecker.Source) -> Bool {
        // Background failures get logged but never pop a dialog —
        // the user didn't ask for this check, so a transient
        // network blip on launch shouldn't interrupt them.
        if case .failed(let reason) = result, source == .background {
            os_log("update check silenced: %{public}@", log: log, type: .info, reason)
            return false
        }
        guard shouldShow(result, source: source) else { return false }
        switch result {
        case .updateAvailable(let info): return showUpdate(info: info)
        case .upToDate: return showUpToDate()
        case .failed: return showFailed()
        case .skipped: return false  // unreachable: shouldShow filters this
        }
    }

    /// Pure decision: should we surface this result? Extracted
    /// from `show(_:source:)` so it's testable without invoking
    /// `NSAlert` or hopping to the main actor. `nonisolated` is
    /// load-bearing — the surrounding enum is `@MainActor` for
    /// `NSAlert.runModal()`, and without this qualifier the
    /// compiler treats the function as main-actor-isolated, which
    /// forces test callers to also be `@MainActor`.
    nonisolated static func shouldShow(_ result: UpdateChecker.Result,
                                       source: UpdateChecker.Source) -> Bool {
        let isManual = (source == .manual)
        switch result {
        case .updateAvailable: return true
        case .upToDate, .failed: return isManual
        case .skipped: return false
        }
    }

    // MARK: - Concrete alerts

    /// Three buttons: "Download" (default, opens URL),
    /// "Skip this version" (writes to `State.skippedVersion`),
    /// "Later" (cancel, no state change). Returns `true` iff the
    /// user chose to download.
    private static func showUpdate(info: UpdateChecker.UpdateInfo) -> Bool {
        let alert = NSAlert()
        alert.messageText = info.headline
        alert.informativeText = informativeText(for: info)
        alert.alertStyle = .informational
        alert.addButton(withTitle: "去下载")
        alert.addButton(withTitle: "稍后")
        alert.addButton(withTitle: "跳过该版本")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(info.htmlURL)
            return true
        case .alertThirdButtonReturn:
            UpdateChecker.State().skippedVersion = info.version
            return false
        default:
            return false
        }
    }

    private static func showUpToDate() -> Bool {
        let alert = NSAlert()
        alert.messageText = "已是最新版本"
        alert.informativeText = "当前运行 v\(AppVersion.short)。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
        return true
    }

    private static func showFailed() -> Bool {
        let alert = NSAlert()
        alert.messageText = "无法检查更新"
        alert.informativeText = "请检查网络连接后重试。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
        return true
    }

    private static func informativeText(for info: UpdateChecker.UpdateInfo) -> String {
        var lines: [String] = ["当前 v\(AppVersion.short) → 新版 v\(info.version)"]
        if let notes = info.notes, !notes.isEmpty {
            // Trim the release-body to the first few lines so
            // the alert isn't an essay. GitHub's release body
            // is markdown — render as plain text by splitting
            // on newlines and dropping blank lines and
            // formatting markers.
            let summary = notes
                .split(separator: "\n")
                .prefix(8)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                .joined(separator: "\n")
            if !summary.isEmpty {
                lines.append("")
                lines.append(summary)
            }
        }
        return lines.joined(separator: "\n")
    }
}
