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

    /// Last computed state — used to detect transitions.
    private var lastState: StatusState = .working

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

        // A sentinel log entry so the user can confirm the logger is wired
        // up correctly from Console.app / `log show`.
        os_log("腰痛 启动 (subsystem=local.yaotong, category=activity)",
               log: activityLog, type: .info)

        config = ConfigStore()
        stateMachine = StateMachine(
            workMinutes: config.workMinutes,
            restMinutes: config.restMinutes
        )
        mainWindow = MainWindowController(
            config: config,
            appState: appState
        )
        statusBar = StatusBarController(
            config: config,
            mainWindow: mainWindow
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
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
        MainActor.assumeIsolated { tick() }
    }

    private func tick() {
        let now = Date()
        let idle = activity.secondsSinceLastInput()
        let paused = config.isPaused(now: now)
        let computed = stateMachine.tick(now: now, idleSeconds: idle, isPaused: paused)

        // Publish the live timer values to the UI.
        appState.workDurationSeconds = stateMachine.workTime
        appState.restDurationSeconds = stateMachine.restTime
        appState.workThresholdSeconds = TimeInterval(config.workMinutes * 60)
        appState.restThresholdSeconds = TimeInterval(config.restMinutes * 60)

        statusBar.setState(computed)
        _ = lastState

        // Log detected activity types to the system log (visible in
        // Console.app under subsystem "local.yaotong" or via
        // `log show --predicate 'subsystem == "local.yaotong"' --last 5m`).
        if let event = activity.latestActivity() {
            os_log("检测到活动：%{public}@", log: activityLog, type: .info, event.kind.rawValue)
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
