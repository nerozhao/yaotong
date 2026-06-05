import AppKit

/// Standalone progress window for the "下载并安装" flow. Lives
/// outside the main window because the download can finish
/// while the main window is closed (e.g. user dismissed it
/// during the check). Modal-but-not-modal: we don't run a
/// modal session so the URLSession callback can reach the
/// main run loop and update the bar.
@MainActor
final class DownloadProgressWindowController {

    private let window: NSWindow
    private let label: NSTextField
    private let progressBar: NSProgressIndicator
    private let version: String

    init(info: UpdateChecker.UpdateInfo) {
        self.version = info.version

        let label = NSTextField(labelWithString: "正在下载 腰痛 v\(info.version)…")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false

        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = 0
        bar.translatesAutoresizingMaskIntoConstraints = false

        let view = NSView()
        view.addSubview(label)
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            bar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 12),
            bar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            view.widthAnchor.constraint(equalToConstant: 360)
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "正在更新 腰痛"
        window.contentView = view
        window.isReleasedWhenClosed = false
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let size = window.frame.size
            let origin = NSPoint(
                x: screenFrame.midX - size.width / 2,
                y: screenFrame.midY - size.height / 2
            )
            window.setFrameOrigin(origin)
        } else {
            window.center()
        }

        self.window = window
        self.label = label
        self.progressBar = bar
        window.makeKeyAndOrderFront(nil)
    }

    /// Update progress. `total` is nil when the server didn't
    /// send `Content-Length` (rare for GitHub release assets);
    /// in that case we show indeterminate.
    func update(received: Int64, total: Int64?) {
        if let total = total, total > 0 {
            progressBar.isIndeterminate = false
            progressBar.maxValue = Double(total)
            progressBar.doubleValue = Double(received)
            let percent = Int(Double(received) / Double(total) * 100)
            label.stringValue = "正在下载 腰痛 v\(version) — \(percent)%"
        } else {
            progressBar.isIndeterminate = true
            progressBar.startAnimation(nil)
        }
    }

    func close() {
        window.orderOut(nil)
    }
}
