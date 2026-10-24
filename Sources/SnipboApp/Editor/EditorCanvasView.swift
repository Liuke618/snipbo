import AppKit
import SnipboCore

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
    /// Cmd+C: copy without closing.
    var onCopy: (() -> Void)?
    /// Enter: copy and close.
    var onCopyAndClose: (() -> Void)?
    /// Cmd+P: pin the rendered image as a floating window.
    var onPin: (() -> Void)?
    var onSave: (() -> Void)?
    var onSaveAs: (() -> Void)?
    var onEscape: (() -> Void)?
    /// Tab: copy the current annotation color as a hex string.
    var onCopyColor: (() -> Void)?
    /// Called after the zoom level changes so the toolbar readout can refresh.
    var onZoomChanged: (() -> Void)?
    private var textOverlay: TextEditingOverlay?
    /// Image-pixel rects returned by the last recognition. They are drawn over
    /// the current crop and are not part of the document or undo history.
    private(set) var recognitionHighlights: [CGRect] = []

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
        onZoomChanged?()
    }

    /// Sets the zoom while keeping the image point under `anchor` (view
    /// coordinates at the current zoom) at the same viewport position — the
    /// pinch-center anchoring. An axis where the crop is smaller than the
    /// viewport cannot scroll, so it falls back to the centered origin.
    func setZoom(_ newZoom: CGFloat, anchoredAt anchor: CGPoint) {
        let clamped = min(8, max(0.1, newZoom))
        guard let clip = superview as? NSClipView else {
            setZoom(clamped)
            return
        }
        let cropOrigin = controller.document.cropRect.origin
        let imagePoint = CGPoint(
            x: anchor.x / zoom + cropOrigin.x,
            y: anchor.y / zoom + cropOrigin.y
        )
        let offset = CGPoint(
            x: anchor.x - clip.bounds.origin.x,
            y: anchor.y - clip.bounds.origin.y
        )
        setZoom(clamped)
        let newViewPoint = CGPoint(
            x: (imagePoint.x - cropOrigin.x) * clamped,
            y: (imagePoint.y - cropOrigin.y) * clamped
        )
        clip.setBoundsOrigin(CGPoint(
            x: clampedScrollOrigin(newViewPoint.x - offset.x, docSize: frame.width, viewSize: clip.bounds.width),
            y: clampedScrollOrigin(newViewPoint.y - offset.y, docSize: frame.height, viewSize: clip.bounds.height)
        ))
    }

    /// One axis of the scroll-origin clamp: centered when the document is
    /// smaller than the viewport, else held in [0, docSize − viewSize]. This
    /// is the same rule the clip view's `constrainBoundsRect` applies, kept in
    /// one place for the zoom anchoring.
    private func clampedScrollOrigin(_ value: CGFloat, docSize: CGFloat, viewSize: CGFloat) -> CGFloat {
        docSize < viewSize ? (docSize - viewSize) / 2 : max(0, min(value, docSize - viewSize))
    }

    /// Resizes the canvas to the document's current crop at the current zoom
    /// and requests a redraw. Called on every controller change so the canvas
    /// follows crops committed or restored by undo/redo.
    func updateForDocument() {
        let crop = controller.document.cropRect
        let size = CGSize(width: crop.width * zoom, height: crop.height * zoom)
        let resized = frame.size != size
        if resized {
            setFrameSize(size)
        }
        // The clip view re-constrains its bounds origin on scroll and on its
        // own resize, but not when the document view changes size under it.
        // Re-apply the same centering so a crop that shrank stays in the
        // middle of the viewport; a larger document keeps the scroll position,
        // clamped into range.
        if resized, let clip = superview as? NSClipView {
            let origin = CGPoint(
                x: clampedScrollOrigin(clip.bounds.origin.x, docSize: size.width, viewSize: clip.bounds.width),
                y: clampedScrollOrigin(clip.bounds.origin.y, docSize: size.height, viewSize: clip.bounds.height)
            )
            if clip.bounds.origin != origin {
                clip.setBoundsOrigin(origin)
            }
        }
        needsDisplay = true
    }

    func setRecognitionHighlights(_ rects: [CGRect]) {
        recognitionHighlights = rects
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

        for rect in recognitionHighlights {
            let highlight = viewRect(fromImageRect: rect).intersection(bounds)
            guard !highlight.isNull, highlight.width > 0, highlight.height > 0 else { continue }
            NSColor.systemBlue.withAlphaComponent(0.16).setFill()
            NSBezierPath(rect: highlight).fill()
            NSColor.systemBlue.withAlphaComponent(0.85).setStroke()
            let border = NSBezierPath(rect: highlight.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
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
            drawCropOverlays(crop: crop, inView: cropInView)
        }
    }

    /// Shottr-style crop affordances: the aspect ratio inside the top edge of
    /// the draft, the live size badge under it, and the "hit Enter to crop"
    /// hint below that. All move with the draft.
    private func drawCropOverlays(crop: CGRect, inView cropInView: CGRect) {
        if let ratio = aspectText(for: crop.size) {
            drawBadge(ratio, centeredAt: CGPoint(x: cropInView.midX, y: max(10, cropInView.minY + 12)))
        }
        let sizeLine = controller.sizeText(for: crop.size)
        let hintLine = L10n.tr("Hit Enter to crop", "按 Enter 裁剪")
        var badgeY = cropInView.maxY + 18
        if badgeY + 40 > bounds.maxY {
            // Not enough room below (crop reaches the bottom): stack above.
            badgeY = cropInView.minY - 40
        }
        drawBadge(sizeLine, centeredAt: CGPoint(x: cropInView.midX, y: badgeY))
        drawBadge(hintLine, centeredAt: CGPoint(x: cropInView.midX, y: badgeY + 22))
    }

    /// Draws a small rounded label centered on a view point.
    private func drawBadge(_ text: String, centeredAt center: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let pad: CGFloat = 6
        let rect = CGRect(
            x: center.x - textSize.width / 2 - pad,
            y: center.y - textSize.height / 2 - 3,
            width: textSize.width + pad * 2,
            height: textSize.height + 6
        )
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        string.draw(at: CGPoint(x: rect.minX + pad, y: rect.minY + 3))
    }

    /// "W: 2:1" style aspect readout for the crop draft; unusual ratios fall
    /// back to a decimal.
    private func aspectText(for size: CGSize) -> String? {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return nil }
        var a = width, b = height
        while b != 0 { (a, b) = (b, a % b) }
        let divisor = max(1, a)
        let rw = width / divisor, rh = height / divisor
        if rw <= 20, rh <= 20 {
            return "W: \(rw):\(rh)"
        }
        return String(format: "W: %.2f", Double(width) / Double(height))
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
        case .badge(let center, _):
            let diameter = max(24, annotation.style.fontSize)
            geometryBounds = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        case .lens(let center, _, let radius):
            geometryBounds = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
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

    /// Two-finger pinch zoom, anchored at the pinch center (Shottr-style).
    /// Zoom is view state, not part of the document undo history.
    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), anchoredAt: convert(event.locationInWindow, from: nil))
    }

    /// ⌘ + two-finger scroll zooms as well, matching other macOS editors and
    /// giving mouse users the same control; plain scrolling still scrolls.
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            // Wheel notches are line-based and jumpier than precise deltas;
            // scale each event to a gentle percentage step.
            let step = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY / 600
                : event.scrollingDeltaY * 0.01
            let factor = min(2, max(0.2, 1 + step))
            setZoom(zoom * factor, anchoredAt: convert(event.locationInWindow, from: nil))
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // An active crop draft owns Enter (commit) and Escape (cancel).
        if controller.cropDraft != nil {
            switch event.keyCode {
            case 36:
                controller.commitCropDraft()
                return
            case 53:
                controller.cancelCropDraft()
                return
            default:
                break
            }
        }
        // ⇧P toggles logical-point readouts (Shottr-style).
        if modifiers == [.shift],
           event.charactersIgnoringModifiers?.lowercased() == "p" {
            controller.showsLogicalPoints.toggle()
            controller.changed()
            return
        }
        // Tab copies the current color as hex; other Tab uses keep their
        // default focus-navigation behavior.
        if modifiers.isEmpty, event.keyCode == 48 {
            onCopyColor?()
            return
        }
        // Single-key tool switching (Shottr-style): a plain letter picks the
        // matching tool. Modifier chords and the text overlay are untouched.
        if modifiers.intersection([.command, .option, .control, .shift]).isEmpty,
           let characters = event.charactersIgnoringModifiers?.lowercased(),
           let tool = EditorTool.tool(forHotKey: characters) {
            controller.tool = tool
            return
        }
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
            case "p":
                onPin?()
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
            onCopyAndClose?()
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
