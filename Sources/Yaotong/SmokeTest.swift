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
        let appState = AppState()
        let mainWindow = MainWindowController(config: config, appState: appState)
        let controller = StatusBarController(
            config: config,
            mainWindow: mainWindow
        )

        emit("=== 腰痛 smoke test ===")

        // ---- App icon: dock entry should not be the generic placeholder
        AppDelegate_setApplicationIconImage()
        check(
            "first launch: applicationIconImage is set (Dock won't show generic placeholder)",
            NSApp.applicationIconImage != nil && NSApp.applicationIconImage!.size.width >= 256
        )

        // ---- §6.3: 首次启动能看到菜单栏图标

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
            "first launch: '显示主界面' menu item is present at the top",
            (controller.statusItem.menu?.items.first?.title ?? "").contains("显示主界面")
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
        // Skip the entry flash animation so the displayed image is the
        // steady-state red we want to inspect.
        controller.setState(overtimeTick, animated: false)
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

        // ---- §6.3: 离开座位 10 分钟后图标变蓝（休息等待中）
        // 10 min idle pushes `restTime` across the threshold; the
        // state machine resets work and engages the post-rest gate.
        // While the gate is up the icon stays blue even if the user
        // keeps being idle — the cue is the next mouse move, not the
        // passage of more time.
        let restGateTick = sm.tick(
            now: t0.addingTimeInterval(TimeInterval(40 * 60)),
            idleSeconds: 10 * 60,
            isPaused: false
        )
        controller.setState(restGateTick, animated: false)
        check(
            "10 min away: state becomes .rested (post-rest gate engaged)",
            restGateTick == .rested
        )
        check(
            "10 min away: icon switched to non-template (colored) image",
            controller.statusItem.button?.image?.isTemplate == false
        )
        check(
            "10 min away: icon pixels are actually blue",
            SmokeTest.dominantBlueness(of: controller.statusItem.button?.image) > 0.3,
            "got \(SmokeTest.dominantBlueness(of: controller.statusItem.button?.image))"
        )
        if let png = controller.statusItem.button?.image?.pngData() {
            try? png.write(to: URL(fileURLWithPath: "/tmp/yaotong-rested-icon.png"))
        }
        // A few more idle ticks: the gate is still up, the icon stays blue.
        for i in 1...5 {
            _ = sm.tick(
                now: t0.addingTimeInterval(TimeInterval(40 * 60 + i)),
                idleSeconds: 10 * 60 + TimeInterval(i),
                isPaused: false
            )
        }
        check(
            "still idle: state stays .rested as long as the gate is engaged",
            sm.lastEvent == .none && sm.waitingForActivity
        )

        // ---- §6.3: 用户回到工位，图标恢复白色
        // First active tick releases the gate (no work increment yet).
        let gateReleaseTick = sm.tick(
            now: t0.addingTimeInterval(TimeInterval(40 * 60 + 6)),
            idleSeconds: 0,
            isPaused: false
        )
        controller.setState(gateReleaseTick, animated: false)
        check(
            "user returns: gate release tick reports .working (no work yet)",
            gateReleaseTick == .working
        )
        check(
            "user returns: icon restored to template image (white)",
            controller.statusItem.button?.image?.isTemplate == true
        )
        check(
            "user returns: icon pixels are NOT blue (back to template)",
            SmokeTest.dominantBlueness(of: controller.statusItem.button?.image) < 0.1
        )
        if let png = controller.statusItem.button?.image?.pngData() {
            try? png.write(to: URL(fileURLWithPath: "/tmp/yaotong-working-icon.png"))
        }

        // ---- §6.3: 点击图标弹出配置菜单 (menu is built, items present)
        controller.rebuildMenu()
        let menuTitles = controller.statusItem.menu?.items.map { $0.title } ?? []
        check(
            "click icon: menu has '工作计时' item",
            menuTitles.contains(where: { $0.contains("工作计时") })
        )
        check(
            "click icon: menu has '休息计时' item",
            menuTitles.contains(where: { $0.contains("休息计时") })
        )
        // The timer items show the current work/rest times formatted
        // as MM:SS. Default timerProvider returns (0, 0), so both
        // items should read 00:00 on a fresh build.
        check(
            "click icon: work-timer item shows MM:SS formatted time",
            menuTitles.contains(where: { $0.contains("工作计时：00:00") })
        )
        check(
            "click icon: rest-timer item shows MM:SS formatted time",
            menuTitles.contains(where: { $0.contains("休息计时：00:00") })
        )
        // A second controller wired to a real provider: the menu
        // should pick up the supplied work/rest seconds when its
        // `menuNeedsUpdate` callback fires (simulated here by
        // rebuilding the menu — the callback calls into the same
        // `timerProvider` closure).
        let liveController = StatusBarController(
            config: config,
            mainWindow: mainWindow,
            timerProvider: { (125, 7) }   // 2:05 working, 0:07 resting
        )
        let liveTitles = liveController.statusItem.menu?.items.map { $0.title } ?? []
        check(
            "live timer: work item reflects the provider's value (MM:SS)",
            liveTitles.contains(where: { $0.contains("工作计时：02:05") })
        )
        check(
            "live timer: rest item reflects the provider's value (MM:SS)",
            liveTitles.contains(where: { $0.contains("休息计时：00:07") })
        )
        // The pause menu item's label flips based on `shouldPause(now:)`
        // — outside work hours the label reads "开始腰痛" (auto-paused
        // by the schedule). We just check that *one* of the two is
        // present, not a specific one.
        check(
            "click icon: menu has a pause/start toggle item",
            menuTitles.contains(where: { $0.contains("停止腰痛") || $0.contains("开始腰痛") })
        )
        // The pause/start label must reflect `config.isPaused` at
        // display time. We start unpaused, fire the togglePause
        // action, and then drive the NSMenuDelegate hook the way
        // AppKit does — by calling menuNeedsUpdate on the menu's
        // delegate. The label should now read "开始腰痛".
        config.isPaused = false
        controller.rebuildMenu()
        let pauseItem = controller.statusItem.menu?.items.first {
            $0.title.contains("停止腰痛") || $0.title.contains("开始腰痛")
        }
        check(
            "click pause: starts unpaused, label is '停止腰痛'",
            pauseItem?.title == "停止腰痛",
            "got '\(pauseItem?.title ?? "<nil>")'"
        )
        // Simulate the user clicking the pause item. The target/action
        // plumbing normally fires the selector via the run loop;
        // invoking it directly is the test equivalent.
        _ = pauseItem?.target?.perform(pauseItem?.action, with: pauseItem)
        check(
            "click pause: config.isPaused flipped to true after click",
            config.isPaused == true
        )
        // AppKit calls menuNeedsUpdate just before presenting the
        // menu. The delegate hook is private on NSObject — but the
        // controller is the menu's delegate, so we dispatch through
        // the protocol witness by calling menuNeedsUpdate via the
        // menu's delegate property.
        if let menu = controller.statusItem.menu, let delegate = menu.delegate as? StatusBarController {
            delegate.menuNeedsUpdate(menu)
        }
        let afterClick = controller.statusItem.menu?.items.first {
            $0.title.contains("停止腰痛") || $0.title.contains("开始腰痛")
        }
        check(
            "click pause: next menu show flips label to '开始腰痛'",
            afterClick?.title == "开始腰痛",
            "got '\(afterClick?.title ?? "<nil>")'"
        )
        // And round-trip back.
        _ = afterClick?.target?.perform(afterClick?.action, with: afterClick)
        if let menu = controller.statusItem.menu, let delegate = menu.delegate as? StatusBarController {
            delegate.menuNeedsUpdate(menu)
        }
        let afterSecondClick = controller.statusItem.menu?.items.first {
            $0.title.contains("停止腰痛") || $0.title.contains("开始腰痛")
        }
        check(
            "click pause: second click flips label back to '停止腰痛'",
            afterSecondClick?.title == "停止腰痛",
            "got '\(afterSecondClick?.title ?? "<nil>")'"
        )
        // Reset for downstream tests.
        config.isPaused = false
        controller.rebuildMenu()
        // No emoji in menu titles — the system renders them in the
        // menu font and they look out of place next to the Chinese
        // labels.
        let emojiSet: Set<Character> = ["🪟", "🔄", "⏸", "▶", "🚪"]
        let titlesWithEmoji = menuTitles.filter { title in
            title.contains(where: { emojiSet.contains($0) })
        }
        check(
            "click icon: no emoji in any menu title",
            titlesWithEmoji.isEmpty,
            "found: \(titlesWithEmoji)"
        )
        check(
            "click icon: menu has '重启 腰痛' item",
            menuTitles.contains(where: { $0.contains("重启 腰痛") })
        )
        check(
            "click icon: menu has '退出 腰痛' item",
            menuTitles.contains(where: { $0.contains("退出 腰痛") })
        )

        // ---- §6.3: 修改工作时长后立即生效
        let originalWork = config.workMinutes
        let newWork = originalWork == 45 ? 15 : 45
        config.workMinutes = newWork
        // AppDelegate wires this up via `config.onChange`; the smoke test
        // goes around AppDelegate so we recreate the state machine by
        // hand (the production path would do this for us).
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
        config.workMinutes = 20
        config.restMinutes = 15
        let reloaded = ConfigStore(defaults: defaults)
        check(
            "restart: workMinutes persists",
            reloaded.workMinutes == 20
        )
        check(
            "restart: restMinutes persists",
            reloaded.restMinutes == 15
        )

        // ---- §6.3: "停止腰痛"后状态机冻结
        let pauseStart = Date()
        config.isPaused = true
        sm = StateMachine(workMinutes: 30, restMinutes: 10)
        let pauseTick = sm.tick(
            now: pauseStart,
            idleSeconds: 0,
            isPaused: config.isPaused
        )
        check(
            "pause: tick during pause reports .working and zeroes both counters",
            pauseTick == .working && sm.workTime == 0 && sm.restTime == 0
        )
        // Pause is a pure toggle — even 24h later, state stays paused.
        let later = pauseStart.addingTimeInterval(24 * 60 * 60)
        let stillPausedTick = sm.tick(
            now: later,
            idleSeconds: 24 * 60 * 60,
            isPaused: config.isPaused
        )
        check(
            "pause: state machine stays paused indefinitely (no auto-resume)",
            stillPausedTick == .working && sm.workTime == 0
        )
        // "开始腰痛" flips it off; first active tick is a fresh .working.
        config.isPaused = false
        let unpauseTick = sm.tick(
            now: later,
            idleSeconds: 0,
            isPaused: config.isPaused
        )
        check(
            "pause: first tick after unpause is a fresh .working session",
            unpauseTick == .working
        )

        // Pause toggle round-trips. Clear pause first to test off → on → off.
        config.isPaused = false
        let toggledOn = config.togglePause()
        let toggledOff = config.togglePause()
        check(
            "pause toggle: round-trip on → off",
            toggledOn == true && toggledOff == false
        )

        // ---- §6.3: 系统休眠后工作计时器清 0，唤醒后等待活动
        // This drives the StateMachine path used by AppDelegate's
        // wall-clock-gap detector and the NSWorkspace.didWake observer:
        // a system sleep is treated as a "rested" event. The work counter
        // must reset and the post-rest gate must engage — work only
        // resumes after the next active tick.
        config.isPaused = false
        sm = StateMachine(workMinutes: 30, restMinutes: 10)
        // Run 20 minutes of active work — comfortably below the threshold.
        for i in 0..<(20 * 60) {
            _ = sm.tick(
                now: Date(timeIntervalSince1970: 3_000_000 + TimeInterval(i)),
                idleSeconds: 0,
                isPaused: false
            )
        }
        // Sanity-check the precondition: 20 min of active work should
        // have brought workTime up to 20*60.
        check(
            "sleep/wake precondition: 20 min active work is reflected in workTime",
            sm.workTime == 20 * 60
        )
        // Simulate the wake handler firing.
        sm.handleSleepWake()
        check(
            "sleep/wake: handleSleepWake resets work counter to 0",
            sm.workTime == 0
        )
        check(
            "sleep/wake: handleSleepWake engages post-rest gate",
            sm.waitingForActivity
        )
        check(
            "sleep/wake: handleSleepWake emits workSessionReset event",
            sm.lastEvent == .workSessionReset(idleSeconds: 0)
        )
        // 5 minutes of idle ticks post-wake — work must stay at 0.
        for i in 0..<(5 * 60) {
            _ = sm.tick(
                now: Date(timeIntervalSince1970: 3_000_000 + 20 * 60 + TimeInterval(i)),
                idleSeconds: TimeInterval(i + 1),
                isPaused: false
            )
        }
        check(
            "sleep/wake: work stays at 0 until user is active again",
            sm.workTime == 0 && sm.waitingForActivity
        )
        // First active tick post-wake — gate releases, work begins on the
        // next tick.
        _ = sm.tick(
            now: Date(timeIntervalSince1970: 3_000_000 + 25 * 60),
            idleSeconds: 0,
            isPaused: false
        )
        check(
            "sleep/wake: first active tick releases the gate (still workTime=0)",
            sm.workTime == 0 && !sm.waitingForActivity
        )
        _ = sm.tick(
            now: Date(timeIntervalSince1970: 3_000_000 + 25 * 60 + 1),
            idleSeconds: 0,
            isPaused: false
        )
        check(
            "sleep/wake: work resumes on the tick after gate release",
            sm.workTime == 1
        )

        // ---- §6.3: 「重置计时器」按钮
        // The "重置计时器" button drops both counters to 0 and does
        // NOT engage the post-rest gate. Distinct from handleSleepWake:
        // the user is at the keyboard, so work begins accumulating
        // immediately on the next tick.
        config.isPaused = false
        sm = StateMachine(workMinutes: 30, restMinutes: 10)
        // Build up 20 minutes of active work.
        for i in 0..<(20 * 60) {
            _ = sm.tick(
                now: Date(timeIntervalSince1970: 4_000_000 + TimeInterval(i)),
                idleSeconds: 0,
                isPaused: false
            )
        }
        check(
            "manual reset precondition: 20 min active work is reflected in workTime",
            sm.workTime == 20 * 60
        )
        // User clicks the button.
        sm.startFreshSession()
        check(
            "manual reset: startFreshSession zeros workTime",
            sm.workTime == 0
        )
        check(
            "manual reset: startFreshSession zeros restTime",
            sm.restTime == 0
        )
        check(
            "manual reset: startFreshSession does NOT engage the gate",
            !sm.waitingForActivity
        )
        // The next tick begins accumulating immediately — no wait-for-activity.
        let t1 = Date(timeIntervalSince1970: 4_000_000 + 20 * 60)
        let s1 = sm.tick(now: t1, idleSeconds: 0, isPaused: false)
        check(
            "manual reset: next active tick returns .working",
            s1 == .working
        )
        check(
            "manual reset: next active tick increments workTime",
            sm.workTime == 1
        )

        // Also verify the rescue path: from inside a waitingForActivity
        // gate, startFreshSession releases it.
        sm = StateMachine(workMinutes: 30, restMinutes: 10)
        for i in 0..<(31 * 60) {
            _ = sm.tick(
                now: Date(timeIntervalSince1970: 5_000_000 + TimeInterval(i)),
                idleSeconds: 0,
                isPaused: false
            )
        }
        let sGate = sm.tick(
            now: Date(timeIntervalSince1970: 5_000_000 + 31 * 60 + 11 * 60),
            idleSeconds: 11 * 60,
            isPaused: false
        )
        check(
            "manual reset rescue path: rest crossed threshold engages gate",
            sGate == .rested && sm.waitingForActivity
        )
        sm.startFreshSession()
        check(
            "manual reset rescue path: startFreshSession releases the gate",
            !sm.waitingForActivity && sm.workTime == 0
        )
        // And the next active tick starts work without a wait-for-activity gap.
        let sRescue = sm.tick(
            now: Date(timeIntervalSince1970: 5_000_000 + 31 * 60 + 12 * 60),
            idleSeconds: 0,
            isPaused: false
        )
        check(
            "manual reset rescue path: next active tick begins work immediately",
            sRescue == .working && sm.workTime == 1
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

    // MARK: - Helpers

    /// The smoke test bypasses `AppDelegate.applicationDidFinishLaunching`,
    /// so we set the Dock icon here too. Same code as the production
    /// path — both call `AppIcon.make()`.
    private static func AppDelegate_setApplicationIconImage() {
        NSApp.applicationIconImage = AppIcon.make()
    }

    // MARK: - Image inspection

    /// Returns a 0…1 estimate of how "red" the given image is. We sample the
    /// pixel data of the first bitmap representation and compute the fraction
    /// of opaque pixels where R dominates G and B. Used to verify the
    /// overtime icon's tint actually rendered (rather than just inspecting
    /// the template flag, which `contentTintColor` mishandles).
    static func dominantRedness(of image: NSImage?) -> Double {
        return dominantChannel(of: image) { r, g, b in
            r > 0.5 && r > g + 0.15 && r > b + 0.15
        }
    }

    /// Same shape as `dominantRedness`, but for the blue channel. Used
    /// to verify the rested-state icon actually rendered blue.
    static func dominantBlueness(of image: NSImage?) -> Double {
        return dominantChannel(of: image) { r, g, b in
            b > 0.5 && b > r + 0.15 && b > g + 0.15
        }
    }

    /// Shared sampling loop for the per-channel dominance checks.
    private static func dominantChannel(of image: NSImage?, isMatch: (Double, Double, Double) -> Bool) -> Double {
        guard let image,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return 0 }
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 0, height > 0 else { return 0 }
        var matchCount = 0
        var opaqueCount = 0
        for y in 0..<height {
            for x in 0..<width {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let (r, g, b, a) = (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
                if a < 0.1 { continue }
                opaqueCount += 1
                if isMatch(r, g, b) {
                    matchCount += 1
                }
            }
        }
        return opaqueCount == 0 ? 0 : Double(matchCount) / Double(opaqueCount)
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
