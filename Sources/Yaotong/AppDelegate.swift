import AppKit
import os.log

/// Application entry point. Wires the configuration, state machine, status
/// bar controller, main window, and 1 Hz tick loop together.
@main
struct YaotongApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var config: ConfigStore!
    private var statusBar: StatusBarController!
    private var stateMachine: StateMachine!
    private let activity = SystemActivityMonitor()
    private var tickTimer: Timer?
    private let appState = AppState()
    private var mainWindow: MainWindowController!
    private let updateChecker = UpdateChecker()

    /// Wall-clock time of the previous tick. A jump of more than
    /// `sleepGapThreshold` seconds between two ticks means the system
    /// was asleep (Foundation timers pause while the machine is
    /// sleeping) — we treat that as a rested event so the work
    /// counter doesn't resume mid-cycle after wake.
    private var lastTickWallTime: Date?
    private static let sleepGapThreshold: TimeInterval = 2.0

    /// System log for activity detection — viewable in Console.app or via
    /// `log show --predicate 'subsystem == "local.yaotong"'`.
    private let activityLog = OSLog(subsystem: "local.yaotong", category: "activity")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Smoke-test mode: drive the §6.3 scenarios headlessly and exit.
        if CommandLine.arguments.contains("--smoke-test") {
            SmokeTest.run { [weak self] in
                self?.cleanupAndExit()
            }
            return
        }

        // Provide a custom Dock icon. LSUIElement apps have no icon
        // by default, so when we promote to .regular (i.e., when the
        // main window opens) the Dock would show a generic
        // placeholder. Setting `applicationIconImage` overrides that
        // with our generated red-circle-on-white icon.
        NSApp.applicationIconImage = AppIcon.make()

        // Sentinel so the user can confirm logging works from Console.app
        // (filter by `process:Yaotong` or by `subsystem:local.yaotong`).
        os_log("腰痛启动 — 移动鼠标/按键/滚动后会在此 subsystem 出现活动日志",
               log: activityLog, type: .default)

        config = ConfigStore()
        stateMachine = StateMachine(
            workMinutes: config.workMinutes,
            restMinutes: config.restMinutes
        )
        mainWindow = MainWindowController(
            config: config,
            appState: appState,
            onRestart: { [weak self] in
                self?.restartApp()
            },
            onCheckForUpdates: { [weak self] in
                self?.runUpdateCheck(source: .manual)
            },
            onOpenSource: {
                NSWorkspace.shared.open(UpdateChecker.defaultSourceURL)
            }
        )
        statusBar = StatusBarController(
            config: config,
            mainWindow: mainWindow,
            timerProvider: { [weak self] in
                // Captures `self` weakly so a deallocated AppDelegate
                // never produces a dangling pointer. The state machine
                // reference is read fresh on every call — when the
                // user changes the work/rest thresholds we swap in a
                // new instance, and this closure transparently picks
                // it up without any extra wiring.
                guard let sm = self?.stateMachine else { return (0, 0) }
                return (sm.workTime, sm.restTime)
            },
            onRestart: { [weak self] in
                self?.restartApp()
            },
            onCheckForUpdates: { [weak self] in
                self?.runUpdateCheck(source: .manual)
            },
            onOpenSource: {
                NSWorkspace.shared.open(UpdateChecker.defaultSourceURL)
            }
        )

        // Rebuild state machine when the user changes a setting. The
        // status bar menu no longer needs rebuilding here: its only
        // live values (work/rest timers) are read through the
        // `timerProvider` closure, which captures the new machine
        // automatically on its next call.
        config.onChange = { [weak self] newConfig in
            self?.handleConfigChange(newConfig)
        }

        // System sleep/wake handling. NSWorkspace.didWakeNotification is
        // the OS-guaranteed counterpart to wall-clock-gap detection:
        // either path alone has edge cases (timer coalescing can mask
        // short sleeps; notifications can be missed on hard power
        // events), so we use both. The notification is the precise
        // breadcrumb in the system log; the gap check is the safety net.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSystemWake()
            }
        }

        startTicking()

        // Auto-open the main window at launch.
        DispatchQueue.main.async { [weak self] in
            self?.mainWindow?.open()
        }

        // Background update check — debounced so the launch
        // experience isn't blocked on a network round-trip, and
        // throttled inside `runUpdateCheck` so we don't ping the
        // releases API more than once a day.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.runUpdateCheck(source: .background)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: - Tick loop

    private func startTicking() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        // 100 ms tolerance lets the system coalesce wakeups with other
        // 1-second timers on the device — visible power win on laptops.
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
        MainActor.assumeIsolated { tick() }
    }

    private func tick() {
        let now = Date()

        // System-sleep detection via wall-clock gap. Foundation timers
        // pause while the machine is asleep, so a gap much larger than
        // our 1 s interval (tolerance 0.1 s) means the timer was
        // suspended — treat the gap as a rested event so the work
        // counter doesn't resume mid-cycle after wake.
        if let last = lastTickWallTime {
            let gap = now.timeIntervalSince(last)
            if gap > Self.sleepGapThreshold {
                let secs = Int(gap)
                os_log("检测到系统休眠 %{public}d 秒 — 视为已充分休息，重置工作计时器并等待活动",
                       log: activityLog, type: .default, secs)
                stateMachine.handleSleepWake()
            }
        }
        lastTickWallTime = now

        let idle = activity.sample()
        let computed = stateMachine.tick(
            now: now,
            idleSeconds: idle,
            isPaused: config.isPaused
        )

        // Publish the live timer values to the UI.
        appState.workDurationSeconds = stateMachine.workTime
        appState.restDurationSeconds = stateMachine.restTime
        appState.workThresholdSeconds = TimeInterval(config.workMinutes * 60)
        appState.restThresholdSeconds = TimeInterval(config.restMinutes * 60)

        statusBar.setState(computed)

        // State machine transitions are the events the user actually
        // cares about ("工作会话开始" / "休息判定" / "超时判定").
        if stateMachine.lastEvent != .none {
            os_log("%{public}@", log: activityLog, type: .default, stateMachine.lastEvent.logMessage)
        }
        // Note: per-event activity logs ("鼠标点击" / "键盘按键" …) are
        // intentionally suppressed — the throttled 5-second stream was
        // still noise for normal use. The state-machine events above
        // cover everything the user actually needs to see in the log.
    }

    // MARK: - System wake

    /// Called on `NSWorkspace.didWakeNotification`. Mostly we rely on
    /// the wall-clock-gap detector in `tick()`; this handler exists
    /// to (a) make wake events visible in the system log and
    /// (b) cover the rare case where the timer fires before macOS
    /// updates the wall clock (so the gap stays small) — in which
    /// case the next-tick gap detector will still catch it.
    private func handleSystemWake() {
        os_log("系统唤醒 — 视为已充分休息，重置工作计时器并等待活动",
               log: activityLog, type: .default)
        stateMachine.handleSleepWake()
        // Force one UI refresh so the icon shows the "rested" state
        // (blue) immediately rather than waiting up to 1 s for the
        // next tick to pick up the engaged post-rest gate.
        statusBar.setState(.rested)
    }

    // MARK: - Config change handling

    private func handleConfigChange(_ newConfig: ConfigStore) {
        stateMachine = StateMachine(
            workMinutes: newConfig.workMinutes,
            restMinutes: newConfig.restMinutes
        )
    }

    // MARK: - Restart

    /// Relaunch the app by spawning a detached shell that waits
    /// briefly and then `open -n`s the same `.app` bundle, then
    /// terminating the current process.
    ///
    /// The `sleep` is the load-bearing piece: `NSApp.terminate`
    /// tears the run loop down faster than LaunchServices can
    /// spin up a replacement process, so without it the user just
    /// sees the app close. `open -n` (instead of plain `open`)
    /// asks LaunchServices for a new instance even if a single-
    /// instance lock might otherwise be picked up.
    ///
    /// The shell wrapper also lets us quote-escape the bundle
    /// path safely (the build directory can contain spaces and
    /// non-ASCII characters like `腰痛`).
    func restartApp() {
        let path = Bundle.main.bundlePath
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.3 && /usr/bin/open -n '\(escaped)'"]
        do {
            try task.run()
        } catch {
            os_log("restart failed: %{public}@",
                   log: activityLog, type: .error,
                   String(describing: error))
        }
        NSApp.terminate(nil)
    }

    // MARK: - Update check

    /// Run a check and surface the result via `UpdatePrompt`.
    /// Split out from the menu callback so the background launch
    /// path and the manual menu path share the same plumbing.
    private func runUpdateCheck(source: UpdateChecker.Source) {
        Task { [updateChecker] in
            let result = await updateChecker.check(source: source)
            // The source drives whether the result is surfaced —
            // background is silent unless an update is actually
            // available; manual surfaces every outcome so the
            // click feels acknowledged.
            let action = await MainActor.run { UpdatePrompt.show(result, source: source) }
            if case .updateAvailable(let info) = result, action == .downloadAndInstall {
                runDownloadAndInstall(info: info)
            }
        }
    }

    /// Stage 2 of the "下载并安装" flow: download the DMG with
    /// a progress window, then prompt to restart. The download
    /// writes to `~/Library/Application Support/Yaotong/Updates/`
    /// (not `Caches/`) so the file survives a reboot — the
    /// helper script reads it back after the main app exits.
    private func runDownloadAndInstall(info: UpdateChecker.UpdateInfo) {
        Task { [updateChecker, weak self] in
            let progressController = await MainActor.run { DownloadProgressWindowController(info: info) }
            let destination: URL
            do {
                destination = try await updateChecker.download(info: info, to: UpdateChecker.stagedDMGPath(for: info)) { received, total in
                    Task { @MainActor [weak progressController] in
                        progressController?.update(received: received, total: total)
                    }
                }
            } catch {
                await MainActor.run {
                    progressController.close()
                    UpdatePrompt.showDownloadError(String(describing: error))
                }
                return
            }

            let shouldInstall = await MainActor.run {
                progressController.close()
                return UpdatePrompt.showReadyToInstall(info: info)
            }
            if shouldInstall {
                await self?.performInstall(info: info, dmgPath: destination)
            }
        }
    }

    /// Stage 3: invoke the bundled `update_helper.sh` to swap
    /// the .app bundle and relaunch. The helper is invoked as
    /// a detached process (same trick as `restartApp`) so it
    /// survives our own termination.
    private func performInstall(info: UpdateChecker.UpdateInfo, dmgPath: URL) async {
        guard let helperURL = Bundle.main.url(forResource: "update_helper", withExtension: "sh") else {
            os_log("update_helper.sh not found in bundle", log: activityLog, type: .error)
            await MainActor.run { UpdatePrompt.showDownloadError("更新脚本缺失，请手动重装。") }
            return
        }
        let appPath = Bundle.main.bundlePath
        let mountPoint = "/tmp/yaotong-update-\(ProcessInfo.processInfo.globallyUniqueString)"

        // Single-quote the three path args and escape any
        // embedded single quotes — the same pattern as
        // `restartApp`. The build directory and app name can
        // contain spaces and non-ASCII (`腰痛`), so we can't
        // rely on "no special chars".
        let quote: (String) -> String = { $0.replacingOccurrences(of: "'", with: "'\\''") }
        let script = """
        '\(quote(helperURL.path))' \
        '\(quote(dmgPath.path))' \
        '\(quote(appPath))' \
        '\(quote(mountPoint))' >/dev/null 2>&1
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        do {
            try task.run()
        } catch {
            os_log("install helper launch failed: %{public}@",
                   log: activityLog, type: .error, String(describing: error))
            await MainActor.run { UpdatePrompt.showDownloadError("无法启动安装脚本。") }
            return
        }
        os_log("install helper launched for v%{public}@; quitting for restart",
               log: activityLog, type: .default, info.version)
        NSApp.terminate(nil)
    }

    // MARK: - Smoke test

    private func cleanupAndExit() {
        tickTimer?.invalidate()
        tickTimer = nil
        statusBar = nil
        if CommandLine.arguments.contains("--smoke-test") {
            let code = SmokeTest.lastExitCode
            exit(code)
        }
        NSApp.terminate(nil)
    }
}
