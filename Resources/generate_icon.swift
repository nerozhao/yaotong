// Generates Resources/AppIcon.png — a 1024x1024 white rounded square with
// a red filled circle in the center. The output is what the Dock and
// Finder show for the bundled app.
//
// Invoked by build.sh before copying the .app together. Renders via
// Core Graphics into an NSBitmapImageRep, then writes PNG. macOS scales
// the 1024² image down to the various Dock sizes automatically.
//
// Run from the project root: `swift Resources/generate_icon.swift`.

import AppKit
import CoreGraphics

let size: CGFloat = 1024

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size),
    pixelsHigh: Int(size),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 32
)!

NSGraphicsContext.saveGraphicsState()
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = context

// White rounded-square background — the standard macOS app-icon shape.
let cornerRadius = size * 0.22
let background = NSBezierPath(
    roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
    xRadius: cornerRadius, yRadius: cornerRadius
)
NSColor.white.setFill()
background.fill()

// Blue filled circle in the center.
let inset = size * 0.10
let circleRect = NSRect(
    x: inset,
    y: inset,
    width: size - 2 * inset,
    height: size - 2 * inset
)
NSColor.systemBlue.setFill()
NSBezierPath(ovalIn: circleRect).fill()

NSGraphicsContext.restoreGraphicsState()

let outputPath = "Resources/AppIcon.png"
let pngData = rep.representation(using: .png, properties: [:])!
try pngData.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath)")
