import AppKit

/// Generates the Dock icon at runtime: a white rounded square (macOS
/// app-icon shape) with a red filled circle in the center, matching
/// the menu bar's overtime indicator. Without an explicit
/// `NSApp.applicationIconImage`, the Dock shows a generic placeholder
/// — which is what the user sees when the app is an
/// `LSUIElement=true` background app that promotes itself to
/// `.regular` on demand.
enum AppIcon {
    /// 1024x1024 raster. macOS downscales for smaller Dock sizes
    /// automatically, so we don't need a multi-resolution `.icns`.
    static func make() -> NSImage {
        let size: CGFloat = 1024
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        // White rounded-square background — the standard macOS app-icon shape.
        let cornerRadius = size * 0.22
        let background = NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        NSColor.white.setFill()
        background.fill()

        // Blue filled circle, centered.
        let inset = size * 0.10
        let circleRect = NSRect(
            x: inset,
            y: inset,
            width: size - 2 * inset,
            height: size - 2 * inset
        )
        NSColor.systemBlue.setFill()
        NSBezierPath(ovalIn: circleRect).fill()

        image.unlockFocus()
        return image
    }
}
