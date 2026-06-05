import AppKit
import SwiftUI

/// Manages the (single) main interface window. Auto-opens on launch;
/// also reopened by the status-bar icon's click. Closing the window
/// leaves the app running (the icon stays in the menu bar).
final class MainWindowController {

    private var window: NSWindow?

    private let config: ConfigStore
    private let appState: AppState

    init(config: ConfigStore, appState: AppState) {
        self.config = config
        self.appState = appState
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
            }
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
    }

    /// Called by AppDelegate when the user changes a config setting; the
    /// SwiftUI view already auto-refreshes via @ObservedObject, so this is
    /// a no-op for now — kept as an extension point.
    func refresh() {}
}
