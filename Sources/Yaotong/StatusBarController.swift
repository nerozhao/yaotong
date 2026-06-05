import AppKit

/// Owns the `NSStatusItem` (the icon in the macOS menu bar) and its dropdown
/// menu. Pure AppKit glue — does no work/rest logic of its own.
final class StatusBarController: NSObject {

    // MARK: - Public

    /// Update the icon to reflect the supplied state. Called once per second
    /// by the app's tick loop.
    func setState(_ state: StatusState) {
        switch state {
        case .working:
            // Template image = system label color (white on the dark menu bar).
            // `contentTintColor` on `NSStatusItem.button` does NOT actually
            // tint SF Symbols — only the template flag does.
            statusItem.button?.image = StatusBarController.workingIcon()
        case .overtime:
            // Bake the red color into the SF Symbol via a palette
            // configuration. `contentTintColor` on a non-template image would
            // also work in theory, but on macOS status items it has been
            // observed to be ignored, so we render the tinted image directly.
            statusItem.button?.image = StatusBarController.overtimeIcon()
        }
        statusItem.button?.imagePosition = .imageOnly
    }

    func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Work duration submenu
        let workItem = NSMenuItem(
            title: "工作时长：\(config.workMinutes) 分钟",
            action: nil,
            keyEquivalent: ""
        )
        workItem.submenu = makeDurationSubmenu(
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
            current: config.restMinutes,
            selectHandler: { [weak self] minutes in
                self?.config.restMinutes = minutes
            }
        )
        menu.addItem(restItem)

        menu.addItem(.separator())

        // Pause / resume
        let isPaused = config.isPaused()
        let pauseTitle: String
        if isPaused, let until = config.pauseUntil {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            pauseTitle = "▶ 取消暂停（至 \(formatter.string(from: until))）"
        } else {
            pauseTitle = "⏸ 暂停 1 小时"
        }
        let pauseItem = NSMenuItem(
            title: pauseTitle,
            action: #selector(togglePause(_:)),
            keyEquivalent: ""
        )
        pauseItem.target = self
        menu.addItem(pauseItem)

        menu.addItem(.separator())

        // Debug panel
        if debugWindow != nil {
            let debugItem = NSMenuItem(
                title: "🪟 打开调试面板",
                action: #selector(openDebugPanel(_:)),
                keyEquivalent: "d"
            )
            debugItem.target = self
            menu.addItem(debugItem)
        }

        menu.addItem(.separator())

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
    private let debugWindow: DebugWindowController?
    let statusItem: NSStatusItem

    init(config: ConfigStore, debugWindow: DebugWindowController? = nil) {
        self.config = config
        self.debugWindow = debugWindow
        // Icon-only items use `squareLength`; `variableLength` collapses to
        // zero width when there's no text content.
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        rebuildMenu()
        setState(.working)
    }

    // MARK: - Private helpers

    /// The simplest possible icon: a solid filled circle. Its color
    /// (white / red) is the only signal the user gets.
    private static let symbolName = "circle.fill"

    /// Working-state icon: template, system label color (white on dark menu bar).
    private static func workingIcon() -> NSImage {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "腰痛")
            ?? NSImage()
        let sized = image.withSymbolConfiguration(Self.iconConfig) ?? image
        sized.isTemplate = true
        return sized
    }

    /// Overtime-state icon: red, baked into the image via a palette config.
    /// `applyingSymbolConfiguration(.paletteColors)` is the only reliable way
    /// to color an SF Symbol on a macOS status item — `contentTintColor` on
    /// the button is not honored.
    private static func overtimeIcon() -> NSImage {
        let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: "腰痛")
            ?? NSImage()
        let combined = Self.iconConfig.applying(
            NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        )
        let tinted = base.withSymbolConfiguration(combined) ?? base
        tinted.isTemplate = false
        return tinted
    }

    /// Point size for the circle icon. Matches the macOS menu bar default.
    private static let iconConfig = NSImage.SymbolConfiguration(
        pointSize: 18,
        weight: .regular
    )

    private func makeDurationSubmenu(
        current: Int,
        selectHandler: @escaping (Int) -> Void
    ) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for minutes in ConfigStore.allowedMinuteOptions {
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

    @objc private func openDebugPanel(_ sender: NSMenuItem) {
        debugWindow?.open()
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
