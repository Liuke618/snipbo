import AppKit
import LightShotCore

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
        super.init(frame: CGRect(origin: .zero, size: controller.document.imagePixelSize))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setZoom(_ zoom: CGFloat) {
        self.zoom = min(8, max(0.1, zoom))
        setFrameSize(CGSize(
            width: CGFloat(controller.document.image.width) * self.zoom,
            height: CGFloat(controller.document.image.height) * self.zoom
        ))
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

        if let crop = controller.cropDraft {
            // The crop draft is in image coordinates; the canvas is zoomed.
            let cropInView = CGRect(
                x: crop.minX * zoom,
                y: crop.minY * zoom,
                width: crop.width * zoom,
                height: crop.height * zoom
            )
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

    private func imagePoint(from event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x / zoom, y: point.y / zoom)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        controller.begin(at: imagePoint(from: event))
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
