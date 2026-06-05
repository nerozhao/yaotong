import AppKit

/// Application entry point. Wires the configuration, state machine, status
/// bar controller, main window, and 1 Hz tick loop together.
@main
struct YaotongApp {
    static func main() {
        let app = NSApplication.shared
        // We do all our UI via NSStatusItem + a single main window.
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
    private let appState = AppState()
    private var mainWindow: MainWindowController!

    /// Last computed state — used to detect transitions.
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

        // Auto-open the main window at launch so the user sees their
        // timers immediately.
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

        // Publish the live timer values to the UI.
        appState.workDurationSeconds = stateMachine.workTime
        appState.restDurationSeconds = stateMachine.restTime
        appState.workThresholdSeconds = TimeInterval(config.workMinutes * 60)
        appState.restThresholdSeconds = TimeInterval(config.restMinutes * 60)

        statusBar.setState(computed)
        _ = lastState // keep the field so we can re-introduce state-change logging later
    }

    // MARK: - Config change handling

    private func handleConfigChange(_ newConfig: ConfigStore) {
        // Recreate the state machine so the new thresholds take effect cleanly.
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
