import AppKit
import SnipboCore

final class SelectionOverlayView: NSView {
    let captured: CapturedImage
    var selection = SelectionModel()
    var onConfirm: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onHover: (() -> Void)?

    private var anchor: CGPoint?
    private var moveAnchor: CGPoint?
    private var activeHandle: SelectionHandle?
    private var mousePoint: CGPoint = .zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    init(captured: CapturedImage) {
        self.captured = captured
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
            selection = SelectionModel(rect: CGRect(
                x: min(anchor.x, clamped.x),
                y: min(anchor.y, clamped.y),
                width: abs(clamped.x - anchor.x),
                height: abs(clamped.y - anchor.y)
            ))
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
        }
        needsDisplay = true
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
