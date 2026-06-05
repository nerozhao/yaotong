import AppKit

/// Application entry point. Wires the configuration, state machine, status
/// bar controller and 1 Hz tick loop together.
@main
struct YaotongApp {
    static func main() {
        let app = NSApplication.shared
        // We do all our UI via NSStatusItem; no main window.
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var config: ConfigStore!
    private var statusBar: StatusBarController!
    private var stateMachine: StateMachine!
    private var activity: ActivityProviding = SystemActivityMonitor()
    private var tickTimer: Timer?

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
        statusBar = StatusBarController(config: config)

        // Rebuild menu items when the user changes a setting.
        config.onChange = { [weak self] newConfig in
            self?.handleConfigChange(newConfig)
        }

        startTicking()
    }

    func applicationWillTerminate(_ notification: Notification) {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: - Tick loop

    private func startTicking() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // Common modes so the timer keeps running while the user is in a menu.
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
        // Run an immediate tick so the icon shows the correct color right away.
        tick()
    }

    private func tick() {
        let now = Date()
        let idle = activity.secondsSinceLastInput()
        let paused = config.isPaused(now: now)
        let state = stateMachine.tick(now: now, idleSeconds: idle, isPaused: paused)
        statusBar.setState(state)
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
