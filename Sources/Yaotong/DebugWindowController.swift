import AppKit
import SwiftUI

/// Manages the (single) debug window. `open()` is idempotent — if the
/// window is already on screen it just brings it to the front; otherwise
/// it creates a new one.
final class DebugWindowController {

    private var window: NSWindow?

    private let config: ConfigStore
    private let logStore: LogStore
    private let appState: AppState

    init(config: ConfigStore, logStore: LogStore, appState: AppState) {
        self.config = config
        self.logStore = logStore
        self.appState = appState
    }

    func open(initialTab: DebugView.Tab = .config) {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = DebugView(
            config: config,
            logStore: logStore,
            appState: appState,
            initialTab: initialTab
        )
        let host = NSHostingController(rootView: content)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "腰痛 — 调试面板"
        win.contentViewController = host
        win.isReleasedWhenClosed = false
        win.center()

        // Tie the window's life to its release-when-closed flag so closing
        // the window doesn't kill the controller — we can re-open it.
        let center = NotificationCenter.default
        center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            // Keep the window object alive (we re-show the same one) but
            // let the user feel like it closed. SwiftUI hosting controller
            // is fine to keep around.
            self?.window?.orderOut(nil)
        }

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
