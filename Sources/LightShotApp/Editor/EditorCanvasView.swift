import AppKit
import LightShotCore

/// Displays the document's current crop. All annotation storage is in original
/// image pixels; this view shows `document.cropRect` at `zoom`, so it converts
/// between view points and image points with the crop origin and zoom.
@MainActor
final class EditorCanvasView: NSView {
    unowned let controller: EditorController
    private(set) var zoom: CGFloat = 1
    var onFit: (() -> Void)?
    var onActualSize: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(controller: EditorController) {
        self.controller = controller
        super.init(frame: CGRect(origin: .zero, size: controller.document.cropRect.size))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setZoom(_ zoom: CGFloat) {
        self.zoom = min(8, max(0.1, zoom))
        updateForDocument()
    }

    /// Resizes the canvas to the document's current crop at the current zoom
    /// and requests a redraw. Called on every controller change so the canvas
    /// follows crops committed or restored by undo/redo.
    func updateForDocument() {
        let crop = controller.document.cropRect
        let size = CGSize(width: crop.width * zoom, height: crop.height * zoom)
        if frame.size != size {
            setFrameSize(size)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image = controller.render(includeDraft: true) else { return }
        NSImage(cgImage: image, size: bounds.size).draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )

        if let selected = selectedAnnotation, let box = imageBounds(of: selected) {
            drawSelectionBox(viewRect(fromImageRect: box).insetBy(dx: -3, dy: -3))
        }

        if let crop = controller.cropDraft {
            // The crop draft is in image coordinates; the canvas is zoomed and
            // shows only the current crop.
            let cropInView = viewRect(fromImageRect: crop)
            NSColor.black.withAlphaComponent(0.4).setFill()
            let path = NSBezierPath(rect: bounds)
            path.append(NSBezierPath(rect: cropInView))
            path.windingRule = .evenOdd
            path.fill()
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: cropInView)
            border.lineWidth = 1
            border.stroke()
        }
    }

    private var selectedAnnotation: Annotation? {
        guard let selectedID = controller.selectedID else { return nil }
        return controller.document.annotations.first(where: { $0.id == selectedID })
    }

    /// Image-pixel bounds of the annotation's geometry.
    private func imageBounds(of annotation: Annotation) -> CGRect? {
        let geometryBounds: CGRect
        switch annotation.geometry {
        case .rect(let rect):
            geometryBounds = rect
        case .line(let start, let end):
            geometryBounds = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
        case .path(let points):
            guard let first = points.first else { return nil }
            var minX = first.x
            var minY = first.y
            var maxX = first.x
            var maxY = first.y
            for point in points.dropFirst() {
                minX = min(minX, point.x)
                minY = min(minY, point.y)
                maxX = max(maxX, point.x)
                maxY = max(maxY, point.y)
            }
            geometryBounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .text(let origin, let width, _):
            geometryBounds = CGRect(
                x: origin.x,
                y: origin.y,
                width: width,
                height: annotation.style.fontSize * 1.4
            )
        }
        return geometryBounds
    }

    /// Converts an original-image-pixel rect to crop-relative view coordinates.
    private func viewRect(fromImageRect rect: CGRect) -> CGRect {
        let cropOrigin = controller.document.cropRect.origin
        return CGRect(
            x: (rect.minX - cropOrigin.x) * zoom,
            y: (rect.minY - cropOrigin.y) * zoom,
            width: rect.width * zoom,
            height: rect.height * zoom
        )
    }

    private func drawSelectionBox(_ rect: CGRect) {
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1
        NSColor.white.setStroke()
        path.stroke()
        path.setLineDash([4, 4], count: 2, phase: 0)
        NSColor.black.setStroke()
        path.stroke()
    }

    private func imagePoint(from event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let cropOrigin = controller.document.cropRect.origin
        return CGPoint(
            x: point.x / zoom + cropOrigin.x,
            y: point.y / zoom + cropOrigin.y
        )
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // Keep the select hit radius at ~8 view points at any zoom.
        controller.begin(at: imagePoint(from: event), tolerance: 8 / zoom)
    }

    override func mouseDragged(with event: NSEvent) {
        controller.drag(to: imagePoint(from: event))
    }

    override func mouseUp(with event: NSEvent) {
        controller.end(at: imagePoint(from: event))
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            if event.modifierFlags.contains(.shift) {
                controller.redo()
            } else {
                controller.undo()
            }
            return
        }
        if event.charactersIgnoringModifiers == "0" {
            onFit?()
            return
        }
        if event.charactersIgnoringModifiers == "1" {
            onActualSize?()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            controller.deleteSelected()
            return
        }
        super.keyDown(with: event)
    }
}
