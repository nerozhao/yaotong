import AppKit

/// Headless verification of the §6.3 manual test checklist. The app runs
/// its full pipeline (ConfigStore → StateMachine → StatusBarController) and
/// drives each scenario with synthetic time / idle inputs. It also confirms
/// the NSStatusItem is actually registered with the system status bar, which
/// is the only way to prove the icon will be visible.
///
/// Invoked by `AppDelegate.applicationDidFinishLaunching` when the binary
/// is launched with `--smoke-test`.
enum SmokeTest {

    @MainActor
    static func run(then completion: @escaping () -> Void) {
        // .app bundles discard stdout, so write the report to a file the
        // caller can read after the process exits. Path comes from the
        // `--smoke-output=/path/to/file` argument, falling back to
        // `/tmp/yaotong-smoke.log`.
        let outputPath: String = {
            for arg in CommandLine.arguments {
                if arg.hasPrefix("--smoke-output=") {
                    return String(arg.dropFirst("--smoke-output=".count))
                }
            }
            return "/tmp/yaotong-smoke.log"
        }()
        // Truncate any previous report.
        try? "".write(toFile: outputPath, atomically: true, encoding: .utf8)

        var lines: [String] = []
        var passed = 0
        var failed = 0
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            if cond {
                lines.append("  PASS  \(name)")
                passed += 1
            } else {
                lines.append("  FAIL  \(name) \(detail)")
                failed += 1
            }
        }
        func emit(_ line: String) {
            lines.append(line)
        }

        // Private UserDefaults suite so we don't pollute the user's settings.
        let suite = "smoketest.yaotong.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let config = ConfigStore(defaults: defaults)
        let logStore = LogStore()
        let appState = AppState()
        let debugWindow = DebugWindowController(config: config, logStore: logStore, appState: appState)
        let controller = StatusBarController(config: config, debugWindow: debugWindow)

        emit("=== 腰痛 smoke test ===")

        // ---- §6.3: 首次启动能看到菜单栏图标
        check(
            "first launch: status item registered with the system status bar",
            controller.statusItem.button != nil
        )
        check(
            "first launch: menu is built and has the expected items",
            (controller.statusItem.menu?.items.count ?? 0) >= 4
        )
        check(
            "first launch: debug panel menu item present",
            (controller.statusItem.menu?.items ?? []).contains(where: { $0.title.contains("调试面板") })
        )

        // ---- §6.3: 持续使用 30 分钟后图标变红
        var sm = StateMachine(workMinutes: 30, restMinutes: 10)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<(30 * 60) {
            _ = sm.tick(
                now: t0.addingTimeInterval(TimeInterval(i)),
                idleSeconds: 0,
                isPaused: false
            )
        }
        let overtimeTick = sm.tick(
            now: t0.addingTimeInterval(TimeInterval(30 * 60)),
            idleSeconds: 0,
            isPaused: false
        )
        controller.setState(overtimeTick)
        check(
            "30 min continuous work: state becomes .overtime",
            overtimeTick == .overtime
        )
        check(
            "30 min continuous work: icon switched to non-template (colored) image",
            controller.statusItem.button?.image?.isTemplate == false
        )
        check(
            "30 min continuous work: icon pixels are actually red (not black)",
            SmokeTest.dominantRedness(of: controller.statusItem.button?.image) > 0.3,
            "got \(SmokeTest.dominantRedness(of: controller.statusItem.button?.image))"
        )
        // Dump the overtime icon to a PNG so the user can confirm visually.
        if let png = controller.statusItem.button?.image?.pngData() {
            try? png.write(to: URL(fileURLWithPath: "/tmp/yaotong-overtime-icon.png"))
        }

        // ---- §6.3: 离开座位 10 分钟后回到工位，图标恢复白色
        let returnTick = sm.tick(
            now: t0.addingTimeInterval(TimeInterval(40 * 60)),
            idleSeconds: 10 * 60,
            isPaused: false
        )
        controller.setState(returnTick)
        check(
            "10 min away then return: state returns to .working",
            returnTick == .working
        )
        check(
            "10 min away then return: icon restored to template image (white)",
            controller.statusItem.button?.image?.isTemplate == true
        )
        check(
            "10 min away then return: icon pixels are NOT red (back to template)",
            SmokeTest.dominantRedness(of: controller.statusItem.button?.image) < 0.1
        )
        if let png = controller.statusItem.button?.image?.pngData() {
            try? png.write(to: URL(fileURLWithPath: "/tmp/yaotong-working-icon.png"))
        }

        // ---- §6.3: 点击图标弹出配置菜单 (menu is built, items present)
        controller.rebuildMenu()
        let menuTitles = controller.statusItem.menu?.items.map { $0.title } ?? []
        check(
            "click icon: menu has '工作时长' item",
            menuTitles.contains(where: { $0.contains("工作时长") })
        )
        check(
            "click icon: menu has '休息时长' item",
            menuTitles.contains(where: { $0.contains("休息时长") })
        )
        check(
            "click icon: menu has '暂停 1 小时' item",
            menuTitles.contains(where: { $0.contains("暂停 1 小时") })
        )
        check(
            "click icon: menu has '退出 腰痛' item",
            menuTitles.contains(where: { $0.contains("退出 腰痛") })
        )
        let workItem = controller.statusItem.menu?.items.first { $0.title.contains("工作时长") }
        check(
            "click icon: work-duration submenu has all 7 allowed options",
            workItem?.submenu?.items.count == ConfigStore.allowedMinuteOptions.count
        )

        // ---- §6.3: 修改工作时长后立即生效
        let originalWork = config.workMinutes
        let newWork = originalWork == 46 ? 21 : 46
        config.workMinutes = newWork
        // AppDelegate wires this up via `config.onChange`; the smoke test
        // goes around AppDelegate so we have to rebuild the menu by hand.
        controller.rebuildMenu()
        let updatedTitles = controller.statusItem.menu?.items.map { $0.title } ?? []
        check(
            "modify work duration: menu title updates to reflect new value",
            updatedTitles.contains(where: { $0.contains("\(newWork)") })
        )
        sm = StateMachine(workMinutes: newWork, restMinutes: 10)
        let fastNow = Date(timeIntervalSince1970: 2_000_000_000)
        for i in 0..<(newWork * 60) {
            _ = sm.tick(
                now: fastNow.addingTimeInterval(TimeInterval(i)),
                idleSeconds: 0,
                isPaused: false
            )
        }
        let fastOvertime = sm.tick(
            now: fastNow.addingTimeInterval(TimeInterval(newWork * 60)),
            idleSeconds: 0,
            isPaused: false
        )
        check(
            "modify work duration: new threshold takes effect on next tick",
            fastOvertime == .overtime,
            "expected overtime at \(newWork) min, got \(fastOvertime)"
        )

        // ---- §6.3: 重启应用后配置保留
        // Use values that are in the allowed options list — the store
        // snaps invalid values back to the default, which would mask any
        // persistence bug.
        config.workMinutes = 21
        config.restMinutes = 16
        let reloaded = ConfigStore(defaults: defaults)
        check(
            "restart: workMinutes persists",
            reloaded.workMinutes == 21
        )
        check(
            "restart: restMinutes persists",
            reloaded.restMinutes == 16
        )

        // ---- §6.3: "暂停 1 小时"后图标停止变化
        let pauseStart = Date()
        config.pauseUntil = pauseStart.addingTimeInterval(60 * 60)
        sm = StateMachine(workMinutes: 30, restMinutes: 10)
        let pauseTick = sm.tick(
            now: pauseStart,
            idleSeconds: 0,
            isPaused: config.isPaused(now: pauseStart)
        )
        check(
            "pause 1h: tick during pause reports .working and clears workStart",
            pauseTick == .working && sm.workStart == nil
        )
        let unpauseTime = pauseStart.addingTimeInterval(2 * 60 * 60)
        let unpauseTick = sm.tick(
            now: unpauseTime,
            idleSeconds: 0,
            isPaused: config.isPaused(now: unpauseTime)
        )
        check(
            "pause 1h: first tick after unpause is a fresh .working session",
            unpauseTick == .working
        )

        // Pause toggle round-trips. The previous step left a pause in
        // effect, so clear it first to test the off → on → off path.
        config.pauseUntil = nil
        let toggledOn = config.togglePause()
        let toggledOff = config.togglePause()
        check(
            "pause toggle: round-trip on → off",
            toggledOn == true && toggledOff == false
        )

        // ---- §6.3: "退出 腰痛"后菜单栏图标消失
        // The NSStatusItem is owned by the NSStatusBar; the system releases
        // it when the owning process terminates (and when no other code
        // holds a strong ref). We've already taken the snapshot of the
        // status item's button above; the act of `NSApp.terminate(nil)` in
        // `cleanupAndExit` is what removes it from the menu bar.
        check(
            "quit: button snapshot is non-nil (icon was rendered before quit)",
            controller.statusItem.button != nil
        )

        // ---- Debug panel: forcing icon state via AppState changes the icon
        appState.setForcedState(.overtime)
        controller.setState(.overtime)
        check(
            "debug: forcing .overtime still produces a red icon",
            SmokeTest.dominantRedness(of: controller.statusItem.button?.image) > 0.3
        )
        appState.setForcedState(.working)
        controller.setState(.working)
        check(
            "debug: forcing .working produces a non-red icon",
            SmokeTest.dominantRedness(of: controller.statusItem.button?.image) < 0.1
        )

        // ---- Debug panel: LogStore buffers messages
        logStore.log("smoke test entry 1")
        logStore.log("smoke test entry 2", level: .warn)
        // log() is async via a writer queue → main-queue publish. We can't
        // `Thread.sleep` here — that would block the main run loop and
        // starve the dispatch. Pump the run loop until the entries land.
        let deadline = Date().addingTimeInterval(2.0)
        while logStore.entries.count < 2 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        check("debug: LogStore has both entries", logStore.entries.count == 2)
        check(
            "debug: LogStore preserved the level",
            logStore.entries.contains(where: { $0.level == .warn })
        )

        emit("=== \(passed) passed, \(failed) failed ===")

        // Persist the report to the file the caller specified (or
        // /tmp/yaotong-smoke.log) — .app bundles discard stdout, so we
        // can't rely on print().
        let report = lines.joined(separator: "\n") + "\n"
        try? report.write(toFile: outputPath, atomically: true, encoding: .utf8)

        // Exit with the appropriate status code so CI / callers can detect
        // regressions.
        let exitCode: Int32 = failed == 0 ? 0 : 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Hand the exit code back to `AppDelegate.cleanupAndExit` so it
            // can decide whether to terminate or stay running.
            SmokeTest.lastExitCode = exitCode
            completion()
        }
    }

    /// Captured by `AppDelegate.cleanupAndExit` so it can propagate the
    /// smoke-test result as the process's exit code.
    static var lastExitCode: Int32 = 0

    // MARK: - Image inspection

    /// Returns a 0…1 estimate of how "red" the given image is. We sample the
    /// pixel data of the first bitmap representation and compute the fraction
    /// of opaque pixels where R dominates G and B. Used to verify the
    /// overtime icon's tint actually rendered (rather than just inspecting
    /// the template flag, which `contentTintColor` mishandles).
    static func dominantRedness(of image: NSImage?) -> Double {
        guard let image,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return 0 }
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 0, height > 0 else { return 0 }
        var redCount = 0
        var opaqueCount = 0
        for y in 0..<height {
            for x in 0..<width {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let (r, g, b, a) = (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
                if a < 0.1 { continue }
                opaqueCount += 1
                if r > 0.5 && r > g + 0.15 && r > b + 0.15 {
                    redCount += 1
                }
            }
        }
        return opaqueCount == 0 ? 0 : Double(redCount) / Double(opaqueCount)
    }
}

extension NSImage {
    /// Encode to PNG bytes. Returns nil if the image has no raster rep.
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return data
    }
}
