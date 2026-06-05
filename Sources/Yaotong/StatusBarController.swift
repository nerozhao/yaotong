import AppKit

/// Owns the `NSStatusItem` (the icon in the macOS menu bar) and its dropdown
/// menu. Pure AppKit glue — does no work/rest logic of its own.
final class StatusBarController: NSObject {

    // MARK: - Public

    /// Update the icon to reflect the supplied state. Called once per second
    /// by the app's tick loop.
    func setState(_ state: StatusState) {
        // We always keep the same SF Symbol; only the tint changes.
        let image = StatusBarController.makeIcon()
        switch state {
        case .working:
            // Default system label color (appears white on the dark menu bar).
            image.isTemplate = true
            statusItem.button?.contentTintColor = nil
        case .overtime:
            image.isTemplate = false
            statusItem.button?.contentTintColor = .systemRed
        }
        statusItem.button?.image = image
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
    let statusItem: NSStatusItem

    init(config: ConfigStore) {
        self.config = config
        // Icon-only items use `squareLength`; `variableLength` collapses to
        // zero width when there's no text content.
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        rebuildMenu()
        setState(.working)
    }

    // MARK: - Private helpers

    private static func makeIcon() -> NSImage {
        // `figure.stand` reads as "person standing up" — fits the app's purpose
        // of reminding the user to stand up and move.
        // We let AppKit pick the default menu-bar point size, which keeps the
        // icon visually consistent with neighbouring system status items.
        return NSImage(systemSymbolName: "figure.stand", accessibilityDescription: "腰痛")
            ?? NSImage()
    }

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
