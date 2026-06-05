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

    /// System log for activity detection — viewable in Console.app or via
    /// `log show --predicate 'subsystem == "local.yaotong"'`.
    private let activityLog = OSLog(subsystem: "local.yaotong", category: "activity")

    /// Wall-clock time of the last activity-kind log. The detector
    /// fires on every input event, but a one-liner per five seconds
    /// is plenty for confirming the subsystem is alive.
    private var lastActivityLog: Date = .distantPast
    private static let activityLogInterval: TimeInterval = 5

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
            }
        )
        statusBar = StatusBarController(
            config: config,
            mainWindow: mainWindow,
            onRestart: { [weak self] in
                self?.restartApp()
            }
        )

        // Rebuild state machine + menu when the user changes a setting.
        config.onChange = { [weak self] newConfig in
            self?.handleConfigChange(newConfig)
        }

        startTicking()

        // Auto-open the main window at launch.
        DispatchQueue.main.async { [weak self] in
            self?.mainWindow?.open()
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
        let (idle, activityEvent) = activity.sample()
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

        // Raw activity ("鼠标点击" / "键盘按键" …) throttled to once per
        // 5 s — the per-event stream is too noisy to be useful.
        if let activityEvent, now.timeIntervalSince(lastActivityLog) >= Self.activityLogInterval {
            os_log("检测到活动：%{public}@", log: activityLog, type: .default, activityEvent.kind.rawValue)
            lastActivityLog = now
        }
    }

    // MARK: - Config change handling

    private func handleConfigChange(_ newConfig: ConfigStore) {
        stateMachine = StateMachine(
            workMinutes: newConfig.workMinutes,
            restMinutes: newConfig.restMinutes
        )
        statusBar.rebuildMenu()
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
