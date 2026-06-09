import AppKit

/// Owns the `NSStatusItem` (the icon in the macOS menu bar) and its dropdown
/// menu. Pure AppKit glue — does no work/rest logic of its own.
final class StatusBarController: NSObject, NSMenuDelegate {

    // MARK: - Public

    /// Update the icon to reflect the supplied state. Called once per second
    /// by the app's tick loop. Looks like a setter but it just swaps the
    /// cached `NSImage` — no work to do on the common (no-change) path
    /// beyond the pointer swap.
    ///
    /// Transitioning into `.overtime` from a non-overtime state triggers a
    /// brief red flash so the user notices the threshold crossing without
    /// having to look at the menu bar. Subsequent ticks while still in
    /// overtime (the common case during a long work session) just
    /// re-assert the solid red icon.
    ///
    /// - Parameter animated: When `false`, the overtime entry flash is
    ///   skipped and the icon is set to its steady-state color
    ///   immediately. Used by the smoke test to inspect the tinting
    ///   without racing the flash timer.
    func setState(_ state: StatusState, animated: Bool = true) {
        let previous = currentState
        currentState = state
        cancelFlash()

        switch state {
        case .working:
            statusItem.button?.image = workingImage
        case .rested:
            statusItem.button?.image = restedImage
        case .overtime:
            if previous == .overtime || !animated {
                // Long-overtime path, or a test that wants the
                // steady-state image without the animation.
                statusItem.button?.image = overtimeImage
            } else {
                startOvertimeFlash()
            }
        }
    }

    func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        // 第一项：显示主界面
        if mainWindow != nil {
            let showMain = NSMenuItem(
                title: "显示主界面",
                action: #selector(showMainWindow(_:)),
                keyEquivalent: ""
            )
            showMain.target = self
            menu.addItem(showMain)
            menu.addItem(.separator())
        }

        // 检查更新 — 紧跟主界面之后，作为另一个"看一眼就走"的轻量动作
        let checkItem = NSMenuItem(
            title: "检查更新…",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkItem.target = self
        menu.addItem(checkItem)
        // 查看源码 — 同行，链接到 GitHub repo
        let sourceItem = NSMenuItem(
            title: "查看源码",
            action: #selector(openSource(_:)),
            keyEquivalent: ""
        )
        sourceItem.target = self
        menu.addItem(sourceItem)
        menu.addItem(.separator())

        // 工作计时 — 显示当前 workTime（不实时刷新，仅在菜单弹出时取值）
        let snapshot = timerProvider()
        workTimerItem = NSMenuItem(
            title: "工作计时：\(Self.formatMMSS(snapshot.work))",
            action: nil,
            keyEquivalent: ""
        )
        workTimerItem?.isEnabled = false
        menu.addItem(workTimerItem!)

        // 休息计时 — 显示当前 restTime（同上）
        restTimerItem = NSMenuItem(
            title: "休息计时：\(Self.formatMMSS(snapshot.rest))",
            action: nil,
            keyEquivalent: ""
        )
        restTimerItem?.isEnabled = false
        menu.addItem(restTimerItem!)

        menu.addItem(.separator())

        // "重置计时器" — user-declared "I just rested, start the work
        // timer now". Distinct from the pause toggle (which freezes
        // detection) and the work/rest threshold submenus (which only
        // change future thresholds). Sits above the pause toggle so
        // the user's "I'm starting work" intent is closest to the
        // top-level action.
        let resetItem = NSMenuItem(
            title: "重置计时器",
            action: #selector(manualReset(_:)),
            keyEquivalent: ""
        )
        resetItem.target = self
        menu.addItem(resetItem)

        // Pause / resume (pure toggle, no auto-resume). Title flips
        // based on `config.isPaused`; we cache the item so
        // `menuNeedsUpdate` can keep the label current regardless of
        // whether the user toggled via the menu bar or the main
        // window's button.
        pauseItem = NSMenuItem(
            title: Self.pauseTitle(isPaused: config.isPaused),
            action: #selector(togglePause(_:)),
            keyEquivalent: ""
        )
        pauseItem?.target = self
        menu.addItem(pauseItem!)

        menu.addItem(.separator())

        // Restart
        let restartItem = NSMenuItem(
            title: "重启 腰痛",
            action: #selector(restartApp(_:)),
            keyEquivalent: ""
        )
        restartItem.target = self
        menu.addItem(restartItem)

        // Quit
        let quitItem = NSMenuItem(
            title: "退出 腰痛",
            action: #selector(quitApp(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Init

    private let config: ConfigStore
    private let mainWindow: MainWindowController?
    private let timerProvider: () -> (work: TimeInterval, rest: TimeInterval)
    private let onRestart: () -> Void
    private let onManualReset: () -> Void
    private let onCheckForUpdates: () -> Void
    private let onOpenSource: () -> Void
    let statusItem: NSStatusItem

    /// Cached SF Symbol images, built once. The old code rebuilt them
    /// every tick — roughly 3 600 NSImage allocations per hour — even
    /// though the state almost never changes.
    private let workingImage: NSImage
    private let overtimeImage: NSImage
    private let restedImage: NSImage

    /// The last state we were told to show. Used to detect the
    /// *transition* into `.overtime` so we flash exactly once, not on
    /// every tick of a long overtime session.
    private var currentState: StatusState = .working

    /// Active flash timer for the `.overtime` entry animation.
    /// `nil` when no flash is in progress.
    private var flashTimer: Timer?

    /// Strong refs to the three items whose titles depend on live
    /// state, so `menuNeedsUpdate` can refresh them just before the
    /// menu pops up. The menu also retains each via `addItem`; these
    /// references are rebound on every `rebuildMenu()`, at which
    /// point the previous item (no longer reachable through the menu
    /// either) is freed.
    private var workTimerItem: NSMenuItem?
    private var restTimerItem: NSMenuItem?
    private var pauseItem: NSMenuItem?

    init(config: ConfigStore,
         mainWindow: MainWindowController? = nil,
         timerProvider: @escaping () -> (work: TimeInterval, rest: TimeInterval) = { (0, 0) },
         onRestart: @escaping () -> Void = {},
         onManualReset: @escaping () -> Void = {},
         onCheckForUpdates: @escaping () -> Void = {},
         onOpenSource: @escaping () -> Void = {}) {
        self.config = config
        self.mainWindow = mainWindow
        self.timerProvider = timerProvider
        self.onRestart = onRestart
        self.onManualReset = onManualReset
        self.onCheckForUpdates = onCheckForUpdates
        self.onOpenSource = onOpenSource
        // Icon-only items use `squareLength`; `variableLength` collapses to
        // zero width when there's no text content.
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.workingImage = StatusBarController.makeWorkingIcon()
        self.overtimeImage = StatusBarController.makeOvertimeIcon()
        self.restedImage = StatusBarController.makeRestedIcon()
        super.init()
        statusItem.button?.imagePosition = .imageOnly
        rebuildMenu()
        setState(.working)
    }

    // MARK: - Private helpers

    /// SF Symbol name for the menu-bar icon. The color (white / red) is
    /// the only signal the user gets.
    private static let symbolName = "circle.fill"

    /// Point size for the circle icon. Matches the macOS menu bar default.
    private static let iconConfig = NSImage.SymbolConfiguration(
        pointSize: 18,
        weight: .regular
    )

    /// Working-state icon: template, system label color (white on dark menu bar).
    private static func makeWorkingIcon() -> NSImage {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "腰痛")
            ?? NSImage()
        let sized = image.withSymbolConfiguration(Self.iconConfig) ?? image
        sized.isTemplate = true
        return sized
    }

    /// Build a non-template icon tinted with a single color via a SF
    /// Symbol palette config. `contentTintColor` on the status-item
    /// button is not honored for SF Symbols, so the color has to be
    /// baked into the image itself.
    private static func makeTintedIcon(_ color: NSColor) -> NSImage {
        let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: "腰痛")
            ?? NSImage()
        let combined = Self.iconConfig.applying(
            NSImage.SymbolConfiguration(paletteColors: [color])
        )
        let tinted = base.withSymbolConfiguration(combined) ?? base
        tinted.isTemplate = false
        return tinted
    }

    /// Overtime-state icon: red. Shown after the work threshold.
    private static func makeOvertimeIcon() -> NSImage {
        makeTintedIcon(.systemRed)
    }

    /// Rested-state icon: blue. Shown after the rest threshold, while
    /// the post-rest gate is engaged and we are waiting for the user
    /// to become active again.
    private static func makeRestedIcon() -> NSImage {
        makeTintedIcon(.systemBlue)
    }

    // MARK: - Overtime flash

    /// Number of "on" pulses during the overtime entry flash. The full
    /// sequence is `flashCount` reds separated by short blanks,
    /// settling on solid red.
    private static let flashCount = 3
    /// Per-step duration of the flash. Short enough that the whole
    /// sequence finishes well under two seconds — long enough that
    /// each blink is unmistakably visible.
    private static let flashStepInterval: TimeInterval = 0.18

    /// Run the entry flash: alternate the button's image between
    /// the red overtime icon and `nil` (which makes the menu bar
    /// cell show its background) for a few cycles, then leave the
    /// icon solid red.
    private func startOvertimeFlash() {
        // Pre-computed pattern: red, off, red, off, red, off, red (settle).
        // Length = flashCount * 2 - 1 pulses before the settle step.
        var pattern: [Bool] = []
        for i in 0..<(Self.flashCount * 2 - 1) {
            // Even indices are "on" (red), odd are "off" (blank).
            pattern.append(i % 2 == 0)
        }
        var step = 0
        let timer = Timer(timeInterval: Self.flashStepInterval, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            // If the state changed mid-flash (e.g. user paused, or
            // ticked into a different state), the surrounding
            // `setState` already invalidated this timer and reset
            // the image — bail out without touching anything.
            guard self.currentState == .overtime, self.flashTimer === timer else {
                timer.invalidate()
                return
            }
            if step >= pattern.count {
                // Final settle on solid red.
                timer.invalidate()
                if self.flashTimer === timer {
                    self.flashTimer = nil
                }
                self.statusItem.button?.image = self.overtimeImage
                return
            }
            self.statusItem.button?.image = pattern[step] ? self.overtimeImage : nil
            step += 1
        }
        RunLoop.main.add(timer, forMode: .common)
        flashTimer = timer
    }

    private func cancelFlash() {
        flashTimer?.invalidate()
        flashTimer = nil
    }

    // MARK: - NSMenuDelegate

    /// Called by AppKit just before the dropdown menu is shown to the
    /// user. This is the spot to refresh anything that may have changed
    /// since the last `rebuildMenu()` — for us, the work/rest timer
    /// values *and* the pause/start label (the user may have toggled
    /// pause from the main window, leaving the cached menu title
    /// stale). We deliberately do *not* rebuild the whole menu on
    /// every tick: that would be 86 400 NSMenuItem allocations per
    /// day, and the only thing the user actually needs to see updated
    /// in real time is these three labels.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let snapshot = timerProvider()
        workTimerItem?.title = "工作计时：\(Self.formatMMSS(snapshot.work))"
        restTimerItem?.title = "休息计时：\(Self.formatMMSS(snapshot.rest))"
        pauseItem?.title = Self.pauseTitle(isPaused: config.isPaused)
    }

    /// Format a `TimeInterval` as `MM:SS`. Seconds-only resolution —
    /// sub-second precision would flicker twice a second and gain the
    /// user nothing.
    private static func formatMMSS(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    /// Pause/start label. Centralised so `rebuildMenu` and
    /// `menuNeedsUpdate` can't drift apart on a future wording tweak.
    private static func pauseTitle(isPaused: Bool) -> String {
        isPaused ? "开始腰痛" : "停止腰痛"
    }

    // MARK: - Actions

    @objc private func togglePause(_ sender: NSMenuItem) {
        config.togglePause()
    }

    @objc private func manualReset(_ sender: NSMenuItem) {
        onManualReset()
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    @objc private func restartApp(_ sender: NSMenuItem) {
        onRestart()
    }

    @objc private func showMainWindow(_ sender: NSMenuItem) {
        mainWindow?.open()
    }

    @objc private func checkForUpdates(_ sender: NSMenuItem) {
        onCheckForUpdates()
    }

    @objc private func openSource(_ sender: NSMenuItem) {
        onOpenSource()
    }
}
