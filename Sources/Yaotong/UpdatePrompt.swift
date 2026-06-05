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
    static func show(_ result: UpdateChecker.Result, source: UpdateChecker.Source) -> UpdateAction {
        // Background failures get logged but never pop a dialog —
        // the user didn't ask for this check, so a transient
        // network blip on launch shouldn't interrupt them.
        if case .failed(let reason) = result, source == .background {
            os_log("update check silenced: %{public}@", log: log, type: .info, reason)
            return .later
        }
        guard shouldShow(result, source: source) else { return .later }
        switch result {
        case .updateAvailable(let info): return showUpdate(info: info)
        case .upToDate:
            _ = showUpToDate()
            return .later
        case .failed:
            _ = showFailed()
            return .later
        case .skipped: return .later  // unreachable: shouldShow filters this
        }
    }

    /// Action the user picked from the "发现新版本" alert.
    /// The split between `downloadAndInstall` and
    /// `openInBrowser` only matters when the release has a
    /// `.dmg` asset — the alert drops the auto-install button
    /// otherwise and `downloadAndInstall` can never come back.
    enum UpdateAction {
        /// "下载并安装" — kick off the staged-download-and-restart
        /// flow. Caller drives `UpdateChecker.download` and
        /// then the install prompt.
        case downloadAndInstall
        /// "去下载" — open the release page in the user's
        /// default browser. The user installs manually.
        case openInBrowser
        /// "稍后" — dismiss the alert, no state change.
        case later
        /// "跳过该版本" — dismiss and write `info.version` to
        /// `State.skippedVersion` so this version stops
        /// prompting until a newer one ships.
        case skip
    }

    /// Confirm-with-restart prompt after the DMG has been
    /// downloaded to `~/Library/Application Support/Yaotong/Updates/`.
    /// `true` = user picked "重启并安装", the caller should
    /// invoke the helper and `NSApp.terminate`.
    @discardableResult
    static func showReadyToInstall(info: UpdateChecker.UpdateInfo) -> Bool {
        let alert = NSAlert()
        alert.messageText = "下载完成"
        alert.informativeText = "v\(info.version) 已下载到本地。重启后会自动完成安装。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "重启并安装")
        alert.addButton(withTitle: "稍后")
        let response = alert.runModal()
        return response == .alertFirstButtonReturn
    }

    /// Show an error after a download failed. Distinguishes
    /// "no .dmg asset" (a permanent state for this release) from
    /// transient network/HTTP errors.
    static func showDownloadError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "下载失败"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
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

    /// Four buttons when the release has a `.dmg` asset (full
    /// auto-install path): "下载并安装" (default), "去下载"
    /// (browser fallback), "稍后", "跳过该版本". When `info`
    /// has no `dmgURL`, the install button is dropped and we
    /// fall back to a three-button variant — the same shape as
    /// the pre-auto-update flow.
    private static func showUpdate(info: UpdateChecker.UpdateInfo) -> UpdateAction {
        let alert = NSAlert()
        alert.messageText = info.headline
        alert.informativeText = informativeText(for: info)
        alert.alertStyle = .informational
        if info.dmgURL != nil {
            alert.addButton(withTitle: "下载并安装")
            alert.addButton(withTitle: "去下载")
            alert.addButton(withTitle: "稍后")
            alert.addButton(withTitle: "跳过该版本")
        } else {
            alert.addButton(withTitle: "去下载")
            alert.addButton(withTitle: "稍后")
            alert.addButton(withTitle: "跳过该版本")
        }

        let response = alert.runModal()
        // When the install button is present, the button order is:
        // 0: 下载并安装, 1: 去下载, 2: 稍后, 3: 跳过该版本
        // Without it:
        // 0: 去下载, 1: 稍后, 2: 跳过该版本
        //
        // NSApplication.ModalResponse only has named constants
        // for the first three buttons; the 4th returns rawValue
        // 1003 (1 + first/second/third at 1000/1001/1002). We
        // compare against the raw value directly.
        let fourthButtonResponse = NSApplication.ModalResponse(rawValue: 1003)
        if info.dmgURL != nil {
            switch response {
            case .alertFirstButtonReturn: return .downloadAndInstall
            case .alertSecondButtonReturn:
                NSWorkspace.shared.open(info.htmlURL)
                return .openInBrowser
            case .alertThirdButtonReturn: return .later
            case fourthButtonResponse:
                UpdateChecker.State().skippedVersion = info.version
                return .skip
            default: return .later
            }
        } else {
            switch response {
            case .alertFirstButtonReturn:
                NSWorkspace.shared.open(info.htmlURL)
                return .openInBrowser
            case .alertSecondButtonReturn: return .later
            case .alertThirdButtonReturn:
                UpdateChecker.State().skippedVersion = info.version
                return .skip
            default: return .later
            }
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
