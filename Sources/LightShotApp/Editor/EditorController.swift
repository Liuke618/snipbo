import AppKit
import LightShotCore
import UniformTypeIdentifiers

@MainActor
final class EditorController {
    var document: EditDocument
    let history = DocumentHistory()
    weak var canvas: EditorCanvasView?
    var onChange: (() -> Void)?
    /// Called when a commit or undo/redo changes `document.cropRect`, so the
    /// window can refit the canvas to the new crop.
    var onCropChanged: (() -> Void)?

    var tool: EditorTool = .select {
        didSet {
            // Switching tools mid-crop abandons the draft, matching the
            // single-pending-gesture behavior of the other tools.
            if cropDraft != nil {
                cropDraft = nil
                startPoint = nil
            }
            changed()
        }
    }
    var style = AnnotationStyle()
    private(set) var selectedID: UUID?
    private(set) var draft: Annotation?
    private(set) var cropDraft: CGRect?
    /// Shows readout sizes in logical points (÷backingScale, "pt") instead of
    /// physical pixels; toggled with ⇧P or the options popover.
    var showsLogicalPoints = false
    /// Step number handed to the next counter badge.
    private var counterValue = 0

    private var startPoint: CGPoint?
    private var freehandPoints: [CGPoint] = []
    private var moveState: DocumentState?
    private var moveOrigin: CGPoint?
    /// Identifies the style-edit run whose pre-edit state is already on the
    /// undo stack, so a slider drag or color-panel scrub records one undo
    /// entry instead of one per tick.
    private var styleEditKey: String?

    init(document: EditDocument) {
        self.document = document
    }

    var nextZIndex: Int {
        (document.annotations.map(\.zIndex).max() ?? 0) + 1
    }

    func setSelected(id: UUID?) {
        selectedID = id
        styleEditKey = nil
        changed()
    }

    /// The style of the selected annotation, if any; the toolbar mirrors it.
    var selectedStyle: AnnotationStyle? {
        guard let selectedID else { return nil }
        return document.annotations.first { $0.id == selectedID }?.style
    }

    /// Applies a style change to the selected annotation and to the default
    /// style for new annotations; with nothing selected only the default is
    /// touched. Consecutive changes to the same target share one undo entry.
    func setLineWidth(_ width: CGFloat) {
        applyStyleEdit { $0.lineWidth = width }
    }

    func setColor(_ color: RGBA) {
        applyStyleEdit { $0.color = color }
    }

    private func applyStyleEdit(_ mutate: (inout AnnotationStyle) -> Void) {
        let key = selectedID.map { "annotation:\($0.uuidString)" } ?? "defaults"
        if styleEditKey != key {
            recordState(document.state)
            styleEditKey = key
        }
        if let selectedID,
           let index = document.annotations.firstIndex(where: { $0.id == selectedID }) {
            mutate(&document.annotations[index].style)
        }
        mutate(&style)
        changed()
    }

    /// Records a pre-change state for undo. Any structural edit ends the
    /// current style-edit run so the next style change records its own state.
    private func recordState(_ state: DocumentState) {
        history.record(state)
        styleEditKey = nil
    }

    /// Begins a gesture at `point`, expressed in original image coordinates.
    /// `tolerance` is the select-tool hit radius in image points; callers that
    /// display a zoomed canvas pass `8 / zoom` to keep it constant on screen.
    func begin(at point: CGPoint, tolerance: CGFloat = 8) {
        switch tool {
        case .select:
            if let hit = AnnotationHitTester.topmost(in: document.annotations, at: point, tolerance: tolerance) {
                selectedID = hit.id
                moveState = document.state
                moveOrigin = point
            } else {
                selectedID = nil
            }
        case .arrow, .rectangle, .ellipse, .line, .highlight, .pixelate, .blur, .spotlight:
            startPoint = point
            draft = makeAnnotation(from: point, to: point)
        case .freehand:
            startPoint = point
            freehandPoints = [point]
            draft = Annotation(kind: .freehand, geometry: .path(points: [point]), style: style, zIndex: nextZIndex)
        case .counter:
            // Click places a badge with the next step number; no drag.
            counterValue += 1
            recordState(document.state)
            document.annotations.append(Annotation(
                kind: .counter,
                geometry: .badge(center: point, value: counterValue),
                style: style,
                zIndex: nextZIndex
            ))
            changed()
            return
        case .magnifier:
            // Click places a lens that magnifies the image around itself.
            recordState(document.state)
            document.annotations.append(Annotation(
                kind: .magnifier,
                geometry: .lens(center: point, source: point, radius: max(40, style.fontSize * 1.6)),
                style: style,
                zIndex: nextZIndex
            ))
            changed()
            return
        case .crop:
            startPoint = point
            cropDraft = CGRect(origin: point, size: .zero)
        case .text:
            break
        }
        changed()
    }

    func drag(to point: CGPoint) {
        if tool == .select, let selectedID, let moveOrigin,
           let index = document.annotations.firstIndex(where: { $0.id == selectedID }) {
            if let moveState {
                recordState(moveState)
                self.moveState = nil
            }
            let delta = CGPoint(x: point.x - moveOrigin.x, y: point.y - moveOrigin.y)
            document.annotations[index].geometry = translated(document.annotations[index].geometry, by: delta)
            self.moveOrigin = point
            changed()
            return
        }

        guard let startPoint else { return }
        switch tool {
        case .freehand:
            freehandPoints.append(point)
            draft?.geometry = .path(points: freehandPoints)
        case .crop:
            cropDraft = normalizedRect(from: startPoint, to: point)
        case .arrow, .rectangle, .ellipse, .line, .highlight, .pixelate, .blur, .spotlight:
            draft = makeAnnotation(from: startPoint, to: point)
        default:
            break
        }
        changed()
    }

    func end(at point: CGPoint) {
        defer {
            startPoint = nil
            freehandPoints.removeAll()
            draft = nil
            cropDraft = nil
            moveState = nil
            moveOrigin = nil
            changed()
        }

        switch tool {
        case .select:
            return
        case .crop:
            commitCropDraft()
        case .text:
            return
        default:
            guard let draft, isUsable(draft) else { return }
            recordState(document.state)
            document.annotations.append(draft)
        }
    }

    /// Commits the in-progress crop draft (drag end or Enter). Returns true
    /// when the crop was applied.
    @discardableResult
    func commitCropDraft() -> Bool {
        defer {
            cropDraft = nil
            startPoint = nil
        }
        guard let cropDraft, !cropDraft.isNull,
              cropDraft.width >= 2, cropDraft.height >= 2 else { return false }
        // A crop is always relative to the currently visible crop, so the
        // new rect cannot reveal pixels outside it. Both rects are
        // integral, so the second intersection keeps integral coordinates.
        let clipped = cropDraft.intersection(document.cropRect)
        guard !clipped.isNull else { return false }
        let next = clipped.integral.intersection(document.cropRect)
        guard next.width >= 2, next.height >= 2, next != document.cropRect else { return false }
        recordState(document.state)
        document.cropRect = next
        onCropChanged?()
        changed()
        return true
    }

    /// Abandons the in-progress crop draft (Escape).
    func cancelCropDraft() {
        guard cropDraft != nil else { return }
        cropDraft = nil
        startPoint = nil
        changed()
    }

    /// Replaces the document with the current crop resampled to `newWidth`
    /// (height follows the aspect ratio). Annotations inside the crop are
    /// carried along and scaled; the undo history is dropped because the base
    /// image itself changed, matching Shottr's "can't be undone" resize.
    func resizeImage(toWidth newWidth: CGFloat) {
        let crop = document.cropRect.integral
        guard newWidth >= 8, newWidth <= 20000,
              abs(newWidth - crop.width) >= 1 else { return }
        let factor = newWidth / crop.width
        let target = CGSize(width: newWidth.rounded(), height: (crop.height * factor).rounded())
        guard let cropped = document.image.cropping(to: crop) else { return }
        let resized = ImageExporter.resampled(cropped, to: target)
        var carried: [Annotation] = []
        for var annotation in document.annotations where annotation.bounds.intersects(crop) {
            annotation.geometry = translated(
                annotation.geometry,
                by: CGPoint(x: -crop.minX, y: -crop.minY)
            ).scaled(by: factor)
            annotation.style = annotation.style.scaled(by: factor)
            carried.append(annotation)
        }
        document = EditDocument(image: resized, backingScale: document.backingScale * factor)
        document.annotations = carried
        history.reset()
        selectedID = nil
        onCropChanged?()
        changed()
    }

    /// Formats a size for the readouts, honoring the logical-points toggle:
    /// Retina captures then show ÷scale as "pt" instead of physical pixels.
    func sizeText(for size: CGSize) -> String {
        let scale = document.backingScale
        if showsLogicalPoints, scale > 1 {
            return "\(Int((size.width / scale).rounded()))×\(Int((size.height / scale).rounded())) pt"
        }
        return "\(Int(size.width.rounded()))×\(Int(size.height.rounded())) px"
    }

    func commitText(_ value: String, at point: CGPoint, width: CGFloat) {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        recordState(document.state)
        document.annotations.append(Annotation(
            kind: .text,
            geometry: .text(origin: point, width: width, value: value),
            style: style,
            zIndex: nextZIndex
        ))
        changed()
    }

    func deleteSelected() {
        guard let selectedID,
              let index = document.annotations.firstIndex(where: { $0.id == selectedID }) else { return }
        recordState(document.state)
        document.annotations.remove(at: index)
        self.selectedID = nil
        changed()
    }

    func undo() {
        guard let state = history.undo(current: document.state) else { return }
        applyRestored(state)
    }

    func redo() {
        guard let state = history.redo(current: document.state) else { return }
        applyRestored(state)
    }

    private func applyRestored(_ state: DocumentState) {
        let previousCrop = document.cropRect
        document.apply(state)
        selectedID = nil
        styleEditKey = nil
        if document.cropRect != previousCrop {
            onCropChanged?()
        }
        changed()
    }

    func render(includeDraft: Bool = false) -> CGImage? {
        var copy = document
        if includeDraft, let draft {
            copy.annotations.append(draft)
        }
        return DocumentRenderer.render(copy)
    }

    private func makeAnnotation(from start: CGPoint, to end: CGPoint) -> Annotation {
        switch tool {
        case .rectangle, .ellipse, .pixelate, .blur, .spotlight:
            let kind: AnnotationKind
            switch tool {
            case .ellipse: kind = .ellipse
            case .pixelate: kind = .pixelate
            case .blur: kind = .blur
            case .spotlight: kind = .spotlight
            default: kind = .rectangle
            }
            var effectStyle = style
            // A full-black spotlight would hide everything; default to a
            // moderate dim unless the user already lowered the opacity.
            if tool == .spotlight, effectStyle.opacity >= 1 {
                effectStyle.opacity = 0.55
            }
            return Annotation(kind: kind, geometry: .rect(normalizedRect(from: start, to: end)), style: effectStyle, zIndex: nextZIndex)
        case .arrow:
            return Annotation(kind: .arrow, geometry: .line(start: start, end: end), style: style, zIndex: nextZIndex)
        case .line:
            return Annotation(kind: .line, geometry: .line(start: start, end: end), style: style, zIndex: nextZIndex)
        case .highlight:
            var highlightStyle = style
            highlightStyle.color = .yellow
            highlightStyle.lineWidth = max(style.lineWidth, 14)
            highlightStyle.opacity = 0.35
            return Annotation(kind: .highlight, geometry: .line(start: start, end: end), style: highlightStyle, zIndex: nextZIndex)
        default:
            return Annotation(kind: .rectangle, geometry: .rect(.zero), style: style, zIndex: nextZIndex)
        }
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func isUsable(_ annotation: Annotation) -> Bool {
        switch annotation.geometry {
        case .rect(let rect):
            return rect.width >= 2 && rect.height >= 2
        case .line(let start, let end):
            return hypot(end.x - start.x, end.y - start.y) >= 2
        case .path(let points):
            return points.count >= 2
        case .text(_, _, let value):
            return !value.isEmpty
        case .badge, .lens:
            // Committed directly on click; always usable.
            return true
        }
    }

    private func translated(_ geometry: AnnotationGeometry, by delta: CGPoint) -> AnnotationGeometry {
        switch geometry {
        case .rect(let rect):
            return .rect(rect.offsetBy(dx: delta.x, dy: delta.y))
        case .line(let start, let end):
            return .line(
                start: CGPoint(x: start.x + delta.x, y: start.y + delta.y),
                end: CGPoint(x: end.x + delta.x, y: end.y + delta.y)
            )
        case .path(let points):
            return .path(points: points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) })
        case .text(let origin, let width, let value):
            return .text(origin: CGPoint(x: origin.x + delta.x, y: origin.y + delta.y), width: width, value: value)
        case .badge(let center, let value):
            return .badge(center: CGPoint(x: center.x + delta.x, y: center.y + delta.y), value: value)
        case .lens(let center, let source, let radius):
            // Moving the lens slides the callout; the magnified source point
            // stays fixed so the lens keeps showing the same content.
            return .lens(
                center: CGPoint(x: center.x + delta.x, y: center.y + delta.y),
                source: source,
                radius: radius
            )
        }
    }

    func changed() {
        canvas?.updateForDocument()
        onChange?()
    }
}

enum EditorError: Error {
    case renderFailed
    case encodeFailed
}

extension EditorController {
    /// Renders the document for copy/save. Excludes any in-progress drag draft;
    /// callers commit pending text before calling this.
    func renderForExport() -> CGImage? {
        render()
    }

    func write(_ image: CGImage, to url: URL, format: ImageFormat, quality: Double) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data: Data?
        switch format {
        case .png:
            data = ImageExporter.pngData(from: image)
        case .jpeg:
            data = ImageExporter.jpegData(from: image, quality: quality)
        }
        guard let data else { throw EditorError.encodeFailed }
        try data.write(to: url, options: .atomic)
    }

    func defaultFileName(format: ImageFormat) -> String {
        CaptureFileSaver.defaultFileName(format: format)
    }
}
