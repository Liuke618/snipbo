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
    /// On-device privacy redaction.
    var onRedact: ((RedactionMode) -> Void)?
    /// File name shown when dragging the image out, honoring the configured
    /// template and capture metadata.
    var suggestedExportName: (() -> String)?
    /// Called after the zoom level changes so the toolbar readout can refresh.
    var onZoomChanged: (() -> Void)?
    private var textOverlay: TextEditingOverlay?
    /// Starts a drag-out gesture when the select tool is active and the press
    /// missed every annotation. The view point is captured at mouse-down so
    /// the drag preview appears where the gesture began.
    private var dragOutOrigin: CGPoint?
    private var dragOutTemporaryFile: URL?
    /// Image-pixel rects returned by the last recognition. They are drawn over
    /// the current crop and are not part of the document or undo history.
    private(set) var recognitionHighlights: [CGRect] = []
    private var cachedImage: CGImage?
    private var cachedState: DocumentState?
    private var cachedDraft: Annotation?
    private var cachedScale: CGFloat = 0
    private var cachedImageID: ObjectIdentifier?

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

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    /// Render at the display's pixel density, capped at the image's native
    /// resolution. A fit-to-window 6K screenshot then renders at roughly
    /// view size instead of full 6K on every drag.
    private var displayRenderScale: CGFloat {
        let backing = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        return min(1, max(0.05, zoom * backing))
    }

    /// Reuses the last render unless the document, draft, source image, or
    /// display scale changed. Selection changes and recognition highlights are
    /// drawn on top and do not invalidate it.
    private func imageToDraw() -> CGImage? {
        let document = controller.document
        let state = document.state
        let draft = controller.draft
        let scale = displayRenderScale
        let imageID = ObjectIdentifier(document.image)
        if let cachedImage,
           cachedState == state,
           cachedDraft == draft,
           cachedScale == scale,
           cachedImageID == imageID {
            return cachedImage
        }
        let image = controller.render(includeDraft: true, scale: scale)
        cachedImage = image
        cachedState = state
        cachedDraft = draft
        cachedScale = scale
        cachedImageID = imageID
        return image
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image = imageToDraw() else { return }
        NSImage(cgImage: image, size: bounds.size).draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )

        let selected = controller.selectedAnnotations
        for annotation in selected {
            if let box = imageBounds(of: annotation) {
                drawSelectionBox(viewRect(fromImageRect: box).insetBy(dx: -3, dy: -3))
            }
        }
        if selected.count > 1 {
            let union = selected.dropFirst().reduce(selected[0].bounds) {
                $0.union($1.bounds)
            }
            drawSelectionBox(
                viewRect(fromImageRect: union).insetBy(dx: -6, dy: -6),
                color: .systemBlue
            )
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

    /// Image-pixel bounds of the annotation, including its text layout and
    /// stroke spread, so selection boxes match what was drawn.
    private func imageBounds(of annotation: Annotation) -> CGRect? {
        annotation.bounds
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

    private func drawSelectionBox(_ rect: CGRect, color: NSColor = .white) {
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1
        color.setStroke()
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
        let imagePoint = imagePoint(from: event)
        if controller.tool == .polygon {
            if event.clickCount == 2, controller.isPolygonInProgress {
                _ = controller.commitPolygon()
            } else {
                controller.begin(at: imagePoint)
            }
            return
        }
        // Dragging empty canvas with the select tool exports the rendered
        // image. A press that lands on an annotation keeps moving it instead.
        if controller.tool == .select,
           !event.modifierFlags.contains(.shift),
           AnnotationHitTester.topmost(
               in: controller.document.annotations,
               at: imagePoint,
               tolerance: 8 / zoom
           ) == nil {
            dragOutOrigin = convert(event.locationInWindow, from: nil)
        } else {
            dragOutOrigin = nil
        }
        // Keep the select hit radius at ~8 view points at any zoom.
        controller.begin(
            at: imagePoint,
            tolerance: 8 / zoom,
            extendSelection: event.modifierFlags.contains(.shift)
        )
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
        let style = controller.style
        let fontSize = max(12, style.fontSize * zoom)
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
        editor.font = appFont(for: style, size: fontSize)
        editor.alignment = appAlignment(style.textAlignment)
        editor.textColor = NSColor(style.color)
        if let background = style.textBackground {
            editor.drawsBackground = true
            editor.backgroundColor = NSColor(background)
        } else {
            editor.drawsBackground = false
        }
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.textContainerInset = .zero
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        editor.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
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

    private func appFont(for style: AnnotationStyle, size: CGFloat) -> NSFont {
        var font = style.fontName.flatMap { NSFont(name: $0, size: size) }
            ?? NSFont.systemFont(ofSize: size)
        if style.fontBold == true {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        return font
    }

    private func appAlignment(_ alignment: AnnotationTextAlignment?) -> NSTextAlignment {
        switch alignment ?? .left {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let origin = dragOutOrigin {
            let point = convert(event.locationInWindow, from: nil)
            if hypot(point.x - origin.x, point.y - origin.y) >= 4 {
                dragOutOrigin = nil
                beginImageDrag(with: event, from: origin)
                return
            }
        }
        controller.drag(to: imagePoint(from: event))
    }

    override func mouseUp(with event: NSEvent) {
        dragOutOrigin = nil
        controller.end(at: imagePoint(from: event))
    }

    /// Starts a drag session carrying a temporary PNG plus the rendered
    /// preview. The select tool only reaches this path on empty canvas, so it
    /// cannot interfere with moving or drawing annotations.
    private func beginImageDrag(with event: NSEvent, from origin: CGPoint) {
        guard let image = controller.render(),
              let payload = ImageDragSupport.makePayload(
                  image: image,
                  suggestedName: suggestedExportName?()
                      ?? controller.defaultFileName(format: .png)
              ) else {
            NSSound.beep()
            return
        }
        let frame = NSRect(
            x: origin.x - payload.preview.size.width / 2,
            y: origin.y - payload.preview.size.height / 2,
            width: payload.preview.size.width,
            height: payload.preview.size.height
        )
        payload.item.setDraggingFrame(frame, contents: payload.preview)
        dragOutTemporaryFile = payload.temporaryFile
        let session = beginDraggingSession(with: [payload.item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
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
        // An in-progress polygon owns Enter (close) and Escape (cancel).
        if controller.tool == .polygon, controller.isPolygonInProgress {
            switch event.keyCode {
            case 36:
                _ = controller.commitPolygon()
                return
            case 53:
                controller.cancelPolygon()
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
        if modifiers == [.command, .shift],
           let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "r":
                onRedact?(.sensitiveText)
                return
            case "f":
                onRedact?(.faces)
                return
            case "a":
                onRedact?(.allText)
                return
            default:
                break
            }
        }
        if modifiers == [.command, .option],
           let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "c":
                controller.copySelectedAnnotations()
                return
            case "v":
                controller.pasteAnnotations()
                return
            default:
                break
            }
        }
        if modifiers == [.command],
           let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "a":
                controller.selectAll()
                return
            case "d":
                controller.duplicateSelected()
                return
            default:
                break
            }
        }
        if [123, 124, 125, 126].contains(event.keyCode),
           !controller.selectedIDs.isEmpty {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            switch event.keyCode {
            case 123: controller.nudgeSelected(dx: -step, dy: 0)
            case 124: controller.nudgeSelected(dx: step, dy: 0)
            case 125: controller.nudgeSelected(dx: 0, dy: step)
            default: controller.nudgeSelected(dx: 0, dy: -step)
            }
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

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let selectionCount = controller.selectedIDs.count

        let copy = menuItem(
            L10n.tr("Copy Annotations", "复制标注"),
            action: #selector(copyAnnotations)
        )
        copy.keyEquivalent = "c"
        copy.keyEquivalentModifierMask = [.command, .option]
        copy.isEnabled = selectionCount > 0
        menu.addItem(copy)

        let paste = menuItem(
            L10n.tr("Paste Annotations", "粘贴标注"),
            action: #selector(pasteAnnotations)
        )
        paste.keyEquivalent = "v"
        paste.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(paste)

        let duplicate = menuItem(
            L10n.tr("Duplicate", "再制"),
            action: #selector(duplicateAnnotations)
        )
        duplicate.keyEquivalent = "d"
        duplicate.keyEquivalentModifierMask = [.command]
        duplicate.isEnabled = selectionCount > 0
        menu.addItem(duplicate)

        let delete = menuItem(
            L10n.tr("Delete", "删除"),
            action: #selector(deleteAnnotations)
        )
        delete.isEnabled = selectionCount > 0
        menu.addItem(delete)

        menu.addItem(.separator())

        let selectAll = menuItem(
            L10n.tr("Select All", "全选"),
            action: #selector(selectAllAnnotations)
        )
        selectAll.keyEquivalent = "a"
        selectAll.keyEquivalentModifierMask = [.command]
        menu.addItem(selectAll)

        menu.addItem(.separator())
        let redactItem = NSMenuItem(
            title: L10n.tr("Privacy Redaction", "隐私打码"),
            action: nil,
            keyEquivalent: ""
        )
        let redactMenu = NSMenu()
        let redactModes: [(String, RedactionMode)] = [
            (L10n.tr("Sensitive Text", "敏感文本"), .sensitiveText),
            (L10n.tr("Faces", "人脸"), .faces),
            (L10n.tr("All Text", "全部文字"), .allText),
        ]
        for (title, mode) in redactModes {
            let item = menuItem(title, action: #selector(redactSelected(_:)))
            item.tag = mode.rawValue
            redactMenu.addItem(item)
        }
        redactItem.submenu = redactMenu
        menu.addItem(redactItem)

        if selectionCount >= 2 {
            menu.addItem(.separator())
            let alignItem = NSMenuItem(title: L10n.tr("Align", "对齐"), action: nil, keyEquivalent: "")
            let alignMenu = NSMenu()
            let alignments: [(String, EditorController.Alignment)] = [
                (L10n.tr("Left", "左对齐"), .left),
                (L10n.tr("Center", "水平居中"), .center),
                (L10n.tr("Right", "右对齐"), .right),
                (L10n.tr("Top", "顶对齐"), .top),
                (L10n.tr("Middle", "垂直居中"), .middle),
                (L10n.tr("Bottom", "底对齐"), .bottom),
            ]
            for (index, entry) in alignments.enumerated() {
                let item = menuItem(entry.0, action: #selector(alignAnnotations(_:)))
                item.tag = index
                alignMenu.addItem(item)
            }
            alignItem.submenu = alignMenu
            menu.addItem(alignItem)
        }

        if selectionCount >= 3 {
            let distributeItem = NSMenuItem(
                title: L10n.tr("Distribute", "分布"),
                action: nil,
                keyEquivalent: ""
            )
            let distributeMenu = NSMenu()
            let horizontal = menuItem(
                L10n.tr("Horizontally", "水平分布"),
                action: #selector(distributeAnnotations(_:))
            )
            horizontal.tag = 0
            distributeMenu.addItem(horizontal)
            let vertical = menuItem(
                L10n.tr("Vertically", "垂直分布"),
                action: #selector(distributeAnnotations(_:))
            )
            vertical.tag = 1
            distributeMenu.addItem(vertical)
            distributeItem.submenu = distributeMenu
            menu.addItem(distributeItem)
        }
        return menu
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func copyAnnotations() { controller.copySelectedAnnotations() }
    @objc private func pasteAnnotations() { controller.pasteAnnotations() }
    @objc private func duplicateAnnotations() { controller.duplicateSelected() }
    @objc private func deleteAnnotations() { controller.deleteSelected() }
    @objc private func selectAllAnnotations() { controller.selectAll() }

    @objc private func redactSelected(_ sender: NSMenuItem) {
        guard let mode = RedactionMode(rawValue: sender.tag) else { return }
        onRedact?(mode)
    }

    @objc private func alignAnnotations(_ sender: NSMenuItem) {
        let alignments: [EditorController.Alignment] = [
            .left, .center, .right, .top, .middle, .bottom,
        ]
        guard sender.tag >= 0, sender.tag < alignments.count else { return }
        controller.alignSelected(alignments[sender.tag])
    }

    @objc private func distributeAnnotations(_ sender: NSMenuItem) {
        controller.distributeSelected(horizontal: sender.tag == 0)
    }
}

extension EditorCanvasView: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        ImageDragSupport.removeTemporaryFile(dragOutTemporaryFile)
        dragOutTemporaryFile = nil
    }
}
