import AppKit
import SwiftUI

/// Manages the (single) main interface window. Auto-opens on launch;
/// also reopened by the status-bar icon's click. Closing the window
/// leaves the app running (the icon stays in the menu bar).
final class MainWindowController {

    private var window: NSWindow?

    private let config: ConfigStore
    private let appState: AppState
    private let onRestart: () -> Void

    init(config: ConfigStore,
         appState: AppState,
         onRestart: @escaping () -> Void = {}) {
        self.config = config
        self.appState = appState
        self.onRestart = onRestart
    }

    /// Open the main window. If already open, bring it to the front.
    func open() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = MainView(
            config: config,
            appState: appState,
            onQuit: {
                NSApp.terminate(nil)
            },
            onRestart: onRestart
        )
        let host = NSHostingController(rootView: content)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "腰痛"
        win.contentViewController = host
        win.isReleasedWhenClosed = false
        // Center on the main screen explicitly — `center()` can land above
        // the visible area on multi-monitor setups with the menu bar at the
        // top.
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowSize = win.frame.size
            let origin = NSPoint(
                x: screenFrame.midX - windowSize.width / 2,
                y: screenFrame.midY - windowSize.height / 2 + 100
            )
            win.setFrameOrigin(origin)
        } else {
            win.center()
        }

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Promote to .regular so the app icon appears in the Dock
        // while the main window is visible. Info.plist still has
        // LSUIElement=true as the default (so we're menu-bar-only
        // at launch until `open()` is called).
        NSApp.setActivationPolicy(.regular)

        // Demote back to .accessory when the window closes, so the
        // app goes back to "background only" once the user is done
        // looking at it. `NSWindow.willCloseNotification` fires on
        // the X button as well as programmatic close.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { _ in
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
