import AppKit
import LightShotCore

/// Displays the document's current crop. All annotation storage is in original
/// image pixels; this view shows `document.cropRect` at `zoom`, so it converts
/// between view points and image points with the crop origin and zoom.
@MainActor
final class EditorCanvasView: NSView {
    /// Strong: the controller owns the canvas weakly and never retains it, so a
    /// strong canvas-to-controller edge cannot form a cycle. It also keeps the
    /// controller alive while a closed window's view hierarchy is torn down.
    let controller: EditorController
    private(set) var zoom: CGFloat = 1
    var onFit: (() -> Void)?
    var onActualSize: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onSaveAs: (() -> Void)?
    var onEscape: (() -> Void)?
    private var textOverlay: TextEditingOverlay?

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

    /// Commits the pending text edit, if any, using its current string. The
    /// overlay's commit closure stores the annotation, removes the overlay and
    /// restores canvas focus; empty or whitespace-only text is ignored by
    /// `EditorController.commitText`, but the overlay still closes.
    ///
    /// Exposed to the editor window controller so other actions can commit a
    /// pending edit before acting on the document.
    func commitPendingText() {
        guard let overlay = textOverlay else { return }
        overlay.onCommit?(overlay.string)
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking elsewhere on the canvas commits the pending text edit before
        // starting a new one or any other tool's interaction.
        commitPendingText()
        window?.makeFirstResponder(self)
        if controller.tool == .text {
            presentTextEditor(at: imagePoint(from: event))
            return
        }
        // Keep the select hit radius at ~8 view points at any zoom.
        controller.begin(at: imagePoint(from: event), tolerance: 8 / zoom)
    }

    /// Shows the text entry overlay at an original-image-pixel point and makes
    /// it the first responder so typing reaches it. Any previous overlay is
    /// discarded, matching the single-pending-edit behavior of the tool.
    private func presentTextEditor(at point: CGPoint) {
        textOverlay?.removeFromSuperview()
        let widthInPoints: CGFloat = 260
        // The committed width is in image pixels. Capture it at presentation so
        // a zoom change before commit does not alter the annotation's width.
        let imageWidth = widthInPoints / zoom
        let fontSize = max(12, controller.style.fontSize * zoom)
        // The canvas shows the committed crop zoomed, so map image pixels to
        // crop-relative view points before creating the overlay. The height
        // follows the 1.4x line height used for text annotation bounds so the
        // zoomed font is not clipped.
        let frame = CGRect(
            x: (point.x - controller.document.cropRect.minX) * zoom,
            y: (point.y - controller.document.cropRect.minY) * zoom,
            width: widthInPoints,
            height: max(32, (fontSize * 1.4).rounded(.up))
        )
        let editor = TextEditingOverlay(frame: frame)
        editor.font = .systemFont(ofSize: fontSize)
        editor.textColor = NSColor(controller.style.color)
        editor.drawsBackground = false
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.textContainerInset = .zero
        // NSTextContainer pads lines by 5 points by default; remove it so the
        // text being edited starts where the committed annotation will.
        editor.textContainer?.lineFragmentPadding = 0
        editor.onCommit = { [weak self, weak editor] value in
            guard let self, let editor else { return }
            // `point` stays in original image pixels; only the overlay frame is
            // crop-relative. The committed width is in image pixels too.
            self.controller.commitText(value, at: point, width: imageWidth)
            editor.removeFromSuperview()
            self.textOverlay = nil
            self.window?.makeFirstResponder(self)
        }
        editor.onCancel = { [weak self, weak editor] in
            editor?.removeFromSuperview()
            self?.textOverlay = nil
            self?.window?.makeFirstResponder(self)
        }
        addSubview(editor)
        textOverlay = editor
        window?.makeFirstResponder(editor)
    }

    override func mouseDragged(with event: NSEvent) {
        controller.drag(to: imagePoint(from: event))
    }

    override func mouseUp(with event: NSEvent) {
        controller.end(at: imagePoint(from: event))
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "z":
                if event.modifierFlags.contains(.shift) { controller.redo() } else { controller.undo() }
                return
            case "s":
                if event.modifierFlags.contains(.shift) { onSaveAs?() } else { onSave?() }
                return
            case "c":
                onCopy?()
                return
            default:
                break
            }
        }
        if event.charactersIgnoringModifiers == "0" {
            onFit?()
            return
        }
        if event.charactersIgnoringModifiers == "1" {
            onActualSize?()
            return
        }
        if event.keyCode == 36 {
            onCopy?()
            return
        }
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            controller.deleteSelected()
            return
        }
        super.keyDown(with: event)
    }
}
