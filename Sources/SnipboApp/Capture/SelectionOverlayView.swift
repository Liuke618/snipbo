import AppKit
import SnipboCore

final class SelectionOverlayView: NSView {
    let captured: CapturedImage
    let selectionConstraints: SelectionConstraints
    var selection = SelectionModel()
    var onConfirm: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onHover: (() -> Void)?

    private var anchor: CGPoint?
    private var moveAnchor: CGPoint?
    private var activeHandle: SelectionHandle?
    private var mousePoint: CGPoint = .zero
    /// On-screen layer-0 window edges for this display, in screen-local
    /// top-left coordinates. Empty when snapping is disabled.
    private let windowFrames: [CGRect]

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    init(
        captured: CapturedImage,
        constraints: SelectionConstraints = SelectionConstraints()
    ) {
        self.captured = captured
        self.selectionConstraints = constraints
        self.windowFrames = Self.windowFrames(
            for: captured,
            enabled: constraints.snapToWindows
        )
        super.init(frame: CGRect(origin: .zero, size: captured.geometry.frame.size))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        let nsImage = NSImage(cgImage: captured.image, size: bounds.size)
        nsImage.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)

        if selection.isUsable {
            // Dim only the area outside the selection. The old path drew the
            // full-screen image a second time through a clip, which doubled the
            // pixel cost on every mouse move.
            let dim = NSBezierPath(rect: bounds)
            dim.append(NSBezierPath(rect: selection.rect))
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.45).setFill()
            dim.fill()

            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection.rect)
            border.lineWidth = 1
            border.stroke()
            drawHandles()
            drawSizeLabel()
        } else {
            NSColor.black.withAlphaComponent(0.45).setFill()
            NSBezierPath(rect: bounds).fill()
            drawCrosshair()
        }
        drawMagnifierIfNeeded()
    }

    private func drawHandles() {
        let size: CGFloat = 6
        let points = [
            CGPoint(x: selection.rect.minX, y: selection.rect.minY),
            CGPoint(x: selection.rect.midX, y: selection.rect.minY),
            CGPoint(x: selection.rect.maxX, y: selection.rect.minY),
            CGPoint(x: selection.rect.maxX, y: selection.rect.midY),
            CGPoint(x: selection.rect.maxX, y: selection.rect.maxY),
            CGPoint(x: selection.rect.midX, y: selection.rect.maxY),
            CGPoint(x: selection.rect.minX, y: selection.rect.maxY),
            CGPoint(x: selection.rect.minX, y: selection.rect.midY),
        ]
        NSColor.white.setFill()
        for point in points {
            NSBezierPath(rect: CGRect(
                x: point.x - size / 2,
                y: point.y - size / 2,
                width: size,
                height: size
            )).fill()
        }
    }

    private func drawSizeLabel() {
        let text = "\(Int(selection.rect.width)) × \(Int(selection.rect.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.7),
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = CGPoint(
            x: min(max(selection.rect.minX, 4), bounds.width - size.width - 4),
            y: max(selection.rect.minY - size.height - 6, 4)
        )
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }

    private func drawCrosshair() {
        guard mousePoint != .zero else { return }
        NSColor.white.withAlphaComponent(0.8).setStroke()
        let path = NSBezierPath()
        path.move(to: CGPoint(x: mousePoint.x, y: 0))
        path.line(to: CGPoint(x: mousePoint.x, y: bounds.height))
        path.move(to: CGPoint(x: 0, y: mousePoint.y))
        path.line(to: CGPoint(x: bounds.width, y: mousePoint.y))
        path.lineWidth = 0.5
        path.stroke()
    }

    private func drawMagnifierIfNeeded() {
        guard !selection.isUsable, mousePoint != .zero else { return }
        let zoom: CGFloat = 4
        let diameter: CGFloat = 120
        let sourceSize = diameter / zoom
        let sourceRect = CGRect(
            x: mousePoint.x - sourceSize / 2,
            y: mousePoint.y - sourceSize / 2,
            width: sourceSize,
            height: sourceSize
        )
        let pixelRect = captured.geometry.pixelRect(fromLocalPoints: sourceRect)
        guard let cropped = captured.image.cropping(to: pixelRect) else { return }

        let origin = CGPoint(
            x: min(mousePoint.x + 24, bounds.width - diameter - 8),
            y: min(mousePoint.y + 24, bounds.height - diameter - 8)
        )
        let frame = CGRect(origin: origin, size: CGSize(width: diameter, height: diameter))
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: frame).addClip()
        NSImage(cgImage: cropped, size: frame.size).draw(in: frame)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.setStroke()
        let outline = NSBezierPath(ovalIn: frame)
        outline.lineWidth = 1
        outline.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        mousePoint = point
        onHover?()
        if event.clickCount == 2, selection.isUsable {
            onConfirm?(selection.rect)
            return
        }

        anchor = nil
        moveAnchor = nil
        activeHandle = nil
        // With no usable selection every click starts a new one; a zero rect is
        // within handle tolerance of the origin and must not act as a resize.
        if selection.isUsable,
           let handle = selection.handle(at: point, tolerance: 8),
           handle != .inside {
            activeHandle = handle
        } else if selection.isUsable, selection.rect.contains(point) {
            activeHandle = .inside
            moveAnchor = point
        } else {
            anchor = point
            selection = SelectionModel()
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mousePoint = point
        if let anchor {
            let clamped = CGPoint(
                x: min(max(point.x, bounds.minX), bounds.maxX),
                y: min(max(point.y, bounds.minY), bounds.maxY)
            )
            selection = SelectionModel(rect: newSelectionRect(anchor: anchor, point: clamped))
        } else if activeHandle == .inside, let moveAnchor {
            // SelectionModel.drag(.inside) centers the rect on the supplied point,
            // so pass the center plus the pointer delta to keep the grab offset.
            let delta = CGPoint(x: point.x - moveAnchor.x, y: point.y - moveAnchor.y)
            selection.drag(
                handle: .inside,
                to: CGPoint(x: selection.rect.midX + delta.x, y: selection.rect.midY + delta.y),
                constrainedTo: bounds
            )
            self.moveAnchor = point
        } else if let activeHandle {
            selection.drag(handle: activeHandle, to: point, constrainedTo: bounds)
            var rect = selection.rect
            if let ratio = selectionConstraints.aspectRatio {
                rect = aspectAdjusted(rect, handle: activeHandle, ratio: ratio)
            }
            rect = snapped(rect, handle: activeHandle)
            selection = SelectionModel(rect: clamped(rect))
        }
        needsDisplay = true
    }

    /// Rect for a new drag. Fixed size wins over the aspect ratio; snapping is
    /// only applied to unconstrained drags so it cannot fight either rule.
    private func newSelectionRect(anchor: CGPoint, point: CGPoint) -> CGRect {
        if let fixed = selectionConstraints.fixedSize {
            let size = CGSize(
                width: max(1, fixed.width),
                height: max(1, fixed.height)
            )
            var origin = anchor
            if point.x < anchor.x { origin.x = anchor.x - size.width }
            if point.y < anchor.y { origin.y = anchor.y - size.height }
            return clamped(CGRect(origin: origin, size: size))
        }

        var rect = CGRect(
            x: min(anchor.x, point.x),
            y: min(anchor.y, point.y),
            width: abs(point.x - anchor.x),
            height: abs(point.y - anchor.y)
        )
        if let ratio = selectionConstraints.aspectRatio {
            let signX: CGFloat = point.x < anchor.x ? -1 : 1
            let signY: CGFloat = point.y < anchor.y ? -1 : 1
            var width = max(1, rect.width)
            var height = max(1, rect.height)
            if width / height > ratio {
                height = width / ratio
            } else {
                width = height * ratio
            }
            let maxWidth = signX > 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX
            let maxHeight = signY > 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY
            width = min(width, max(1, maxWidth))
            height = min(height, max(1, maxHeight))
            if width / height > ratio {
                height = width / ratio
            } else {
                width = height * ratio
            }
            let x = signX > 0 ? anchor.x : anchor.x - width
            let y = signY > 0 ? anchor.y : anchor.y - height
            rect = CGRect(x: x, y: y, width: width, height: height)
        } else {
            rect = snapped(
                rect,
                left: point.x < anchor.x,
                right: point.x >= anchor.x,
                top: point.y < anchor.y,
                bottom: point.y >= anchor.y
            )
        }
        return clamped(rect)
    }

    /// Keeps the aspect ratio while dragging a handle. Corner handles pin the
    /// opposite corner; edge handles grow symmetrically around the opposite
    /// edge's midpoint.
    private func aspectAdjusted(
        _ rect: CGRect,
        handle: SelectionHandle,
        ratio: CGFloat
    ) -> CGRect {
        guard rect.width > 0, rect.height > 0 else { return rect }
        switch handle {
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            var width = rect.width
            var height = rect.height
            if width / height > ratio {
                height = width / ratio
            } else {
                width = height * ratio
            }
            let origin: CGPoint
            switch handle {
            case .topLeft:
                origin = CGPoint(x: rect.maxX - width, y: rect.maxY - height)
            case .topRight:
                origin = CGPoint(x: rect.minX, y: rect.maxY - height)
            case .bottomLeft:
                origin = CGPoint(x: rect.maxX - width, y: rect.minY)
            default:
                origin = CGPoint(x: rect.minX, y: rect.minY)
            }
            return CGRect(origin: origin, size: CGSize(width: width, height: height))
        case .left, .right:
            let height = rect.width / ratio
            return CGRect(
                x: rect.minX,
                y: rect.midY - height / 2,
                width: rect.width,
                height: height
            )
        case .top, .bottom:
            let width = rect.height * ratio
            return CGRect(
                x: rect.midX - width / 2,
                y: rect.minY,
                width: width,
                height: rect.height
            )
        case .inside:
            return rect
        }
    }

    private func snapped(
        _ rect: CGRect,
        handle: SelectionHandle
    ) -> CGRect {
        switch handle {
        case .topLeft:
            return snapped(rect, left: true, right: false, top: true, bottom: false)
        case .topRight:
            return snapped(rect, left: false, right: true, top: true, bottom: false)
        case .bottomRight:
            return snapped(rect, left: false, right: true, top: false, bottom: true)
        case .bottomLeft:
            return snapped(rect, left: true, right: false, top: false, bottom: true)
        case .left:
            return snapped(rect, left: true, right: false, top: false, bottom: false)
        case .right:
            return snapped(rect, left: false, right: true, top: false, bottom: false)
        case .top:
            return snapped(rect, left: false, right: false, top: true, bottom: false)
        case .bottom:
            return snapped(rect, left: false, right: false, top: false, bottom: true)
        case .inside:
            return rect
        }
    }

    private func snapped(
        _ rect: CGRect,
        left: Bool,
        right: Bool,
        top: Bool,
        bottom: Bool
    ) -> CGRect {
        guard selectionConstraints.snapToWindows,
              selectionConstraints.fixedSize == nil,
              selectionConstraints.aspectRatio == nil,
              !windowFrames.isEmpty else {
            return rect
        }
        var result = rect
        let xEdges = windowFrames.flatMap { [$0.minX, $0.maxX] }
            + [bounds.minX, bounds.maxX]
        let yEdges = windowFrames.flatMap { [$0.minY, $0.maxY] }
            + [bounds.minY, bounds.maxY]
        if left, let x = nearest(rect.minX, in: xEdges) {
            result.origin.x = x
            result.size.width = rect.maxX - x
        }
        if right, let x = nearest(rect.maxX, in: xEdges) {
            result.size.width = x - result.minX
        }
        if top, let y = nearest(rect.minY, in: yEdges) {
            result.origin.y = y
            result.size.height = rect.maxY - y
        }
        if bottom, let y = nearest(rect.maxY, in: yEdges) {
            result.size.height = y - result.minY
        }
        return result
    }

    private func nearest(_ value: CGFloat, in edges: [CGFloat]) -> CGFloat? {
        let tolerance: CGFloat = 6
        return edges
            .filter { abs($0 - value) <= tolerance }
            .min { abs($0 - value) < abs($1 - value) }
    }

    private func clamped(_ rect: CGRect) -> CGRect {
        var result = rect
        result.size.width = min(max(result.width, 1), bounds.width)
        result.size.height = min(max(result.height, 1), bounds.height)
        result.origin.x = min(max(result.origin.x, bounds.minX), bounds.maxX - result.width)
        result.origin.y = min(max(result.origin.y, bounds.minY), bounds.maxY - result.height)
        return result
    }

    private static func windowFrames(
        for captured: CapturedImage,
        enabled: Bool
    ) -> [CGRect] {
        guard enabled else { return [] }
        let layout = ScreenLayout.current()
        guard let screen = layout.screens.first(where: {
            $0.displayID == captured.geometry.displayID
        }) else { return [] }
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let screenBounds = CGRect(origin: .zero, size: screen.frame.size)
        var frames: [CGRect] = []
        for entry in info {
            guard let owner = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  owner != ownPID,
                  let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  width > 2, height > 2 else {
                continue
            }
            let local = layout.localRect(
                fromCGRect: CGRect(x: x, y: y, width: width, height: height),
                on: screen
            )
            let clipped = local.intersection(screenBounds)
            guard !clipped.isNull, clipped.width > 2, clipped.height > 2 else {
                continue
            }
            frames.append(clipped)
        }
        return frames
    }

    override func mouseUp(with event: NSEvent) {
        anchor = nil
        moveAnchor = nil
        activeHandle = nil
        if !selection.isUsable {
            selection = SelectionModel()
        }
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        mousePoint = convert(event.locationInWindow, from: nil)
        onHover?()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event) {
            super.keyDown(with: event)
        }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 36:
            guard selection.isUsable else {
                NSSound.beep()
                return true
            }
            onConfirm?(selection.rect)
            return true
        case 53:
            onCancel?()
            return true
        case 123, 124, 125, 126:
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let resize = event.modifierFlags.contains(.option)
            if resize {
                // Option+arrow moves that boundary outward in the arrow's
                // direction: Left widens from the left edge, Up from the top.
                switch event.keyCode {
                case 123: selection.resize(edge: .left, by: step, constrainedTo: bounds)
                case 124: selection.resize(edge: .right, by: step, constrainedTo: bounds)
                case 125: selection.resize(edge: .bottom, by: step, constrainedTo: bounds)
                default: selection.resize(edge: .top, by: step, constrainedTo: bounds)
                }
            } else {
                switch event.keyCode {
                case 123: selection.nudge(dx: -step, dy: 0, resize: false, constrainedTo: bounds)
                case 124: selection.nudge(dx: step, dy: 0, resize: false, constrainedTo: bounds)
                case 125: selection.nudge(dx: 0, dy: step, resize: false, constrainedTo: bounds)
                default: selection.nudge(dx: 0, dy: -step, resize: false, constrainedTo: bounds)
                }
            }
            needsDisplay = true
            return true
        default:
            return false
        }
    }
}
