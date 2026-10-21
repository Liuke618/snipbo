#!/usr/bin/env swift
import AppKit

let output = URL(fileURLWithPath: "Resources/AppIcon.iconset", isDirectory: true)
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, size) in variants {
    let side = CGFloat(size)
    // Render into an explicit 1x bitmap so every iconset file has exactly
    // `size` pixels; `NSImage.lockFocus()` would inherit the host display's
    // backing scale and emit 2x images on a Retina Mac.
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }

    bitmap.size = NSSize(width: side, height: side)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.22, alpha: 1).setFill()
    NSBezierPath(
        roundedRect: NSRect(x: 0, y: 0, width: side, height: side),
        xRadius: side * 0.22,
        yRadius: side * 0.22
    ).fill()

    let outerInset = side * 0.16
    let outer = NSBezierPath(ovalIn: NSRect(
        x: outerInset,
        y: outerInset,
        width: side - 2 * outerInset,
        height: side - 2 * outerInset
    ))
    NSColor.white.withAlphaComponent(0.92).setStroke()
    outer.lineWidth = max(1, side * 0.055)
    outer.stroke()

    let innerInset = side * 0.32
    let inner = NSBezierPath(ovalIn: NSRect(
        x: innerInset,
        y: innerInset,
        width: side - 2 * innerInset,
        height: side - 2 * innerInset
    ))
    NSColor(calibratedRed: 0.25, green: 0.72, blue: 0.95, alpha: 1).setFill()
    inner.fill()

    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else { continue }
    try png.write(to: output.appendingPathComponent(name))
}

print("Wrote \(output.path)")
