#!/usr/bin/env swift
import AppKit

// Draws the Snipbo icon — a white five-blade shutter on a purple gradient —
// into an .iconset. Every size is rendered from scratch so the hairline seams
// and the squircle edge stay crisp instead of being downsampled.

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("Resources/AppIcon.iconset", isDirectory: true)
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

func radians(_ degrees: CGFloat) -> CGFloat { degrees * .pi / 180 }

enum Blade {
    // Each blade is a lens: both ends are sharp points, one at r≈0.445 near the
    // centre and one on the rim 111° later. The inner edge stays close to the
    // centre for the first third and then climbs to the rim; the outer edge
    // climbs quickly, merges into the rim and follows it. Neighbouring blades
    // sit 72° apart, so the seams open from a rim notch into the dark star.
    static let span: CGFloat = 111

    static func innerRadius(_ phi: CGFloat) -> CGFloat {
        let t = min(max((phi - 38) / 73, 0), 1)
        return 0.445 + 0.555 * pow(t, 1.7)
    }

    static func outerRadius(_ phi: CGFloat) -> CGFloat {
        let f = 0.445 + 0.555 * pow(max(phi, 0) / 47, 0.85)
        return min(1, f)
    }
}

func appendCatmullRom(_ points: [NSPoint], to path: NSBezierPath, startingNew: Bool) {
    guard points.count > 1 else { return }
    func at(_ index: Int) -> NSPoint { points[min(max(index, 0), points.count - 1)] }
    if startingNew { path.move(to: points[0]) }
    for i in 0..<(points.count - 1) {
        let p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2)
        path.curve(
            to: p2,
            controlPoint1: NSPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
            controlPoint2: NSPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        )
    }
}

struct Pinwheel {
    let center: NSPoint
    let radius: CGFloat

    func point(_ radiusFraction: CGFloat, _ degrees: CGFloat) -> NSPoint {
        let a = radians(degrees)
        return NSPoint(
            x: center.x + radius * radiusFraction * cos(a),
            y: center.y + radius * radiusFraction * sin(a)
        )
    }

    // Both edges share the sampled angles; the blade is one continuous
    // subpath so closing it produces no chords across the centre.
    func blade(start: CGFloat) -> NSBezierPath {
        let steps = Array(stride(from: CGFloat(0), through: Blade.span, by: 3))
        let inner = steps.map { point(Blade.innerRadius($0), start + $0) }
        let outer = steps.reversed().map { point(Blade.outerRadius($0), start + $0) }

        let path = NSBezierPath()
        appendCatmullRom(inner, to: path, startingNew: true)
        appendCatmullRom(outer, to: path, startingNew: false)
        path.close()
        return path
    }

    func innerEdge(start: CGFloat) -> NSBezierPath {
        let steps = Array(stride(from: CGFloat(0), through: Blade.span, by: 3))
        let path = NSBezierPath()
        appendCatmullRom(steps.map { point(Blade.innerRadius($0), start + $0) }, to: path, startingNew: true)
        return path
    }

    var allBlades: [(path: NSBezierPath, start: CGFloat)] {
        (0..<5).map { index in
            let start = 90 + CGFloat(index) * 72
            return (blade(start: start), start)
        }
    }
}

func drawIcon(in context: NSGraphicsContext, side: CGFloat) {
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.current = previous }

    let full = NSRect(x: 0, y: 0, width: side, height: side)
    let corner = side * 0.2237
    let tile = NSBezierPath(roundedRect: full, xRadius: corner, yRadius: corner)

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()

    let background = NSGradient(colors: [
        NSColor(calibratedRed: 0.145, green: 0.110, blue: 0.267, alpha: 1),
        NSColor(calibratedRed: 0.247, green: 0.176, blue: 0.388, alpha: 1),
        NSColor(calibratedRed: 0.435, green: 0.278, blue: 0.576, alpha: 1),
    ])
    background?.draw(from: NSPoint(x: 0, y: side), to: NSPoint(x: side, y: 0), options: [])

    let glow = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.055),
        NSColor.white.withAlphaComponent(0),
    ])
    glow?.draw(
        in: NSBezierPath(ovalIn: full.insetBy(dx: side * 0.10, dy: side * 0.10)),
        relativeCenterPosition: NSPoint(x: 0, y: 0)
    )
    NSGraphicsContext.restoreGraphicsState()

    let pinwheel = Pinwheel(
        center: NSPoint(x: side / 2, y: side / 2),
        radius: side * 0.368
    )
    let blades = pinwheel.allBlades

    // Soft cast shadow under the whole mark.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
    shadow.shadowBlurRadius = side * 0.03
    shadow.shadowOffset = NSSize(width: side * 0.005, height: -side * 0.010)
    shadow.set()
    let union = NSBezierPath()
    for blade in blades { union.append(blade.path) }
    NSColor.black.setFill()
    union.fill()
    NSGraphicsContext.restoreGraphicsState()

    for blade in blades {
        let outerTip = pinwheel.point(1.0, blade.start + Blade.span)
        let innerTip = pinwheel.point(0.445, blade.start)

        NSGraphicsContext.saveGraphicsState()
        blade.path.addClip()

        let face = NSGradient(colors: [
            NSColor(calibratedWhite: 0.86, alpha: 1),
            NSColor(calibratedWhite: 0.975, alpha: 1),
            NSColor(calibratedWhite: 1.0, alpha: 1),
        ])
        face?.draw(
            from: innerTip,
            to: outerTip,
            options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation]
        )

        // Gray groove just inside the inner edge, then a white specular line
        // right on the edge: that pairing is what gives the blades their
        // pressed-metal depth in the reference mark.
        let parts = pinwheel.innerEdge(start: blade.start)
        let groove = NSShadow()
        groove.shadowColor = NSColor(calibratedWhite: 0.45, alpha: 0.45)
        groove.shadowBlurRadius = side * 0.010
        groove.shadowOffset = NSSize(width: 0, height: side * 0.003)
        groove.set()
        NSColor(calibratedWhite: 0.92, alpha: 0.35).setStroke()
        parts.lineWidth = side * 0.006
        parts.stroke()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.75).setStroke()
        blade.path.lineWidth = max(0.55, side * 0.0022)
        blade.path.stroke()
    }

    let border = NSBezierPath(
        roundedRect: full.insetBy(dx: 0.75, dy: 0.75),
        xRadius: corner - 0.75,
        yRadius: corner - 0.75
    )
    NSColor.white.withAlphaComponent(0.07).setStroke()
    border.lineWidth = 1.5
    border.stroke()
}

for (name, size) in variants {
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

    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    drawIcon(in: context, side: CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else { continue }
    try png.write(to: output.appendingPathComponent(name))
}

print("Wrote \(output.path)")
