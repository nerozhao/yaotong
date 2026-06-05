import AppKit

/// Owns the `NSStatusItem` (the icon in the macOS menu bar) and its dropdown
/// menu. Pure AppKit glue — does no work/rest logic of its own.
final class StatusBarController: NSObject {

    // MARK: - Public

    /// Update the icon to reflect the supplied state. Called once per second
    /// by the app's tick loop. Looks like a setter but it just swaps the
    /// cached `NSImage` — no work to do on the common (no-change) path
    /// beyond the pointer swap.
    func setState(_ state: StatusState) {
        statusItem.button?.image = (state == .overtime) ? overtimeImage : workingImage
    }

    func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // 第一项：显示主界面
        if mainWindow != nil {
            let showMain = NSMenuItem(
                title: "🪟 显示主界面",
                action: #selector(showMainWindow(_:)),
                keyEquivalent: ""
            )
            showMain.target = self
            menu.addItem(showMain)
            menu.addItem(.separator())
        }

        // Work duration submenu
        let workItem = NSMenuItem(
            title: "工作时长：\(config.workMinutes) 分钟",
            action: nil,
            keyEquivalent: ""
        )
        workItem.submenu = makeDurationSubmenu(
            options: ConfigStore.allowedWorkMinuteOptions,
            current: config.workMinutes,
            selectHandler: { [weak self] minutes in
                self?.config.workMinutes = minutes
            }
        )
        menu.addItem(workItem)

        // Rest duration submenu
        let restItem = NSMenuItem(
            title: "休息时长：\(config.restMinutes) 分钟",
            action: nil,
            keyEquivalent: ""
        )
        restItem.submenu = makeDurationSubmenu(
            options: ConfigStore.allowedRestMinuteOptions,
            current: config.restMinutes,
            selectHandler: { [weak self] minutes in
                self?.config.restMinutes = minutes
            }
        )
        menu.addItem(restItem)

        menu.addItem(.separator())

        // Pause / resume (pure toggle, no auto-resume)
        let pauseTitle = config.isPaused ? "▶ 开始腰痛" : "⏸ 暂停腰痛"
        let pauseItem = NSMenuItem(
            title: pauseTitle,
            action: #selector(togglePause(_:)),
            keyEquivalent: ""
        )
        pauseItem.target = self
        menu.addItem(pauseItem)

        menu.addItem(.separator())

        // Restart
        let restartItem = NSMenuItem(
            title: "🔄 重启 腰痛",
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
    private let onRestart: () -> Void
    let statusItem: NSStatusItem

    /// Cached SF Symbol images, built once. The old code rebuilt them
    /// every tick — roughly 3 600 NSImage allocations per hour — even
    /// though the state almost never changes.
    private let workingImage: NSImage
    private let overtimeImage: NSImage

    init(config: ConfigStore,
         mainWindow: MainWindowController? = nil,
         onRestart: @escaping () -> Void = {}) {
        self.config = config
        self.mainWindow = mainWindow
        self.onRestart = onRestart
        // Icon-only items use `squareLength`; `variableLength` collapses to
        // zero width when there's no text content.
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.workingImage = StatusBarController.makeWorkingIcon()
        self.overtimeImage = StatusBarController.makeOvertimeIcon()
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

    /// Overtime-state icon: red, baked into the image via a palette config.
    /// `contentTintColor` on the status-item button is not honored for
    /// SF Symbols, so the color has to be in the image itself.
    private static func makeOvertimeIcon() -> NSImage {
        let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: "腰痛")
            ?? NSImage()
        let combined = Self.iconConfig.applying(
            NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        )
        let tinted = base.withSymbolConfiguration(combined) ?? base
        tinted.isTemplate = false
        return tinted
    }

    private func makeDurationSubmenu(
        options: [Int],
        current: Int,
        selectHandler: @escaping (Int) -> Void
    ) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for minutes in options {
            let item = NSMenuItem(
                title: "\(minutes) 分钟",
                action: #selector(durationPicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = DurationChoice(minutes: minutes, handler: selectHandler)
            item.state = (minutes == current) ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    // MARK: - Actions

    @objc private func durationPicked(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? DurationChoice else { return }
        choice.handler(choice.minutes)
    }

    @objc private func togglePause(_ sender: NSMenuItem) {
        config.togglePause()
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

    // MARK: - Private types

    private final class DurationChoice {
        let minutes: Int
        let handler: (Int) -> Void
        init(minutes: Int, handler: @escaping (Int) -> Void) {
            self.minutes = minutes
            self.handler = handler
        }
    }
}
