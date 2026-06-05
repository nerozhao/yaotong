import AppKit

/// Application entry point. Wires the configuration, state machine, status
/// bar controller, log store and 1 Hz tick loop together.
@main
struct YaotongApp {
    static func main() {
        let app = NSApplication.shared
        // We do all our UI via NSStatusItem and the (optional) debug window.
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // Tick is invoked from a Timer callback on the main run loop, so the
    // class is @MainActor to silence concurrency warnings when reading
    // `appState.forcedIconState`.

    private var config: ConfigStore!
    private var statusBar: StatusBarController!
    private var stateMachine: StateMachine!
    private var activity: ActivityProviding = SystemActivityMonitor()
    private var tickTimer: Timer?
    private let logStore = LogStore()
    private let appState = AppState()
    private var debugWindow: DebugWindowController!

    /// Last computed state — used to detect transitions for logging.
    private var lastState: StatusState = .working

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Smoke-test mode: drive the §6.3 scenarios headlessly and exit.
        if CommandLine.arguments.contains("--smoke-test") {
            SmokeTest.run { [weak self] in
                self?.cleanupAndExit()
            }
            return
        }

        config = ConfigStore()
        stateMachine = StateMachine(
            workMinutes: config.workMinutes,
            restMinutes: config.restMinutes
        )
        debugWindow = DebugWindowController(
            config: config,
            logStore: logStore,
            appState: appState
        )
        statusBar = StatusBarController(config: config, debugWindow: debugWindow)

        // Rebuild state machine + menu when the user changes a setting, and
        // emit a log entry so the debug panel can show the change happened.
        config.onChange = { [weak self] newConfig in
            self?.handleConfigChange(newConfig)
        }

        logStore.log("应用启动 — 工作 \(config.workMinutes) 分钟 / 休息 \(config.restMinutes) 分钟")
        startTicking()

        // Optional: open the debug window at launch (used by manual QA and
        // screenshot scripts). `--show-debug=test|log` jumps to that tab.
        let showDebugArg = CommandLine.arguments.first(where: { $0.hasPrefix("--show-debug") })
        if let arg = showDebugArg {
            let tab: DebugView.Tab
            if arg.contains("=test") { tab = .test }
            else if arg.contains("=log") { tab = .log }
            else { tab = .config }
            DispatchQueue.main.async { [weak self] in
                self?.debugWindow?.open(initialTab: tab)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        logStore.log("应用退出")
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: - Tick loop

    private func startTicking() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            // The timer fires on the main run loop, so we can safely assume
            // main-actor isolation here.
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        // Common modes so the timer keeps running while the user is in a menu.
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
        // Run an immediate tick so the icon shows the correct color right away.
        MainActor.assumeIsolated { tick() }
    }

    private func tick() {
        let now = Date()
        let idle = activity.secondsSinceLastInput()
        let paused = config.isPaused(now: now)
        let computed = stateMachine.tick(now: now, idleSeconds: idle, isPaused: paused)
        // Forced state from the debug panel takes precedence.
        let state = appState.forcedIconState ?? computed

        statusBar.setState(state)

        // Log state transitions and pause start/end events (don't spam on
        // every tick).
        if state != lastState {
            if appState.forcedIconState != nil {
                logStore.log("图标状态：手动覆盖 → \(state == .overtime ? "超时(红)" : "工作中(白)")")
            } else {
                logStore.log("图标状态：\(state == .overtime ? "工作中 → 超时" : "超时 → 工作中")")
            }
            lastState = state
        }
    }

    // MARK: - Config change handling

    private func handleConfigChange(_ newConfig: ConfigStore) {
        // Recreate the state machine so the new thresholds take effect cleanly.
        stateMachine = StateMachine(
            workMinutes: newConfig.workMinutes,
            restMinutes: newConfig.restMinutes
        )
        statusBar.rebuildMenu()

        if newConfig.isPaused() {
            logStore.log("配置变更：暂停中（恢复时间 \(newConfig.pauseUntil.map { String(describing: $0) } ?? "?")）")
        } else {
            logStore.log("配置变更：工作 \(newConfig.workMinutes) 分钟 / 休息 \(newConfig.restMinutes) 分钟")
        }
    }

    // MARK: - Smoke test

    private func cleanupAndExit() {
        tickTimer?.invalidate()
        tickTimer = nil
        // Make sure the status item is removed before we quit so it
        // doesn't briefly survive the process.
        statusBar = nil
        // In smoke-test mode, propagate the test result as the exit code.
        if CommandLine.arguments.contains("--smoke-test") {
            let code = SmokeTest.lastExitCode
            // NSApp.terminate uses the app's termination reply; force the
            // raw process exit so the smoke-test result is honoured even
            // when the app was launched as a .app bundle.
            exit(code)
        }
        NSApp.terminate(nil)
    }
}
