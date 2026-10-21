import AppKit
import LightShotCore

@MainActor
final class EditorController {
    var document: EditDocument
    let history = DocumentHistory()
    weak var canvas: EditorCanvasView?
    var onChange: (() -> Void)?

    var tool: EditorTool = .select {
        didSet { changed() }
    }
    var style = AnnotationStyle()
    private(set) var selectedID: UUID?
    private(set) var draft: Annotation?
    private(set) var cropDraft: CGRect?

    private var startPoint: CGPoint?
    private var freehandPoints: [CGPoint] = []
    private var moveState: DocumentState?
    private var moveOrigin: CGPoint?

    init(document: EditDocument) {
        self.document = document
    }

    var nextZIndex: Int {
        (document.annotations.map(\.zIndex).max() ?? 0) + 1
    }

    func setSelected(id: UUID?) {
        selectedID = id
        changed()
    }

    func begin(at point: CGPoint) {
        switch tool {
        case .select:
            if let hit = AnnotationHitTester.topmost(in: document.annotations, at: point, tolerance: 8) {
                selectedID = hit.id
                moveState = document.state
                moveOrigin = point
            } else {
                selectedID = nil
            }
        case .arrow, .rectangle, .ellipse, .line, .highlight, .pixelate:
            startPoint = point
            draft = makeAnnotation(from: point, to: point)
        case .freehand:
            startPoint = point
            freehandPoints = [point]
            draft = Annotation(kind: .freehand, geometry: .path(points: [point]), style: style, zIndex: nextZIndex)
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
                history.record(moveState)
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
        case .arrow, .rectangle, .ellipse, .line, .highlight, .pixelate:
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
            guard let cropDraft, cropDraft.width >= 2, cropDraft.height >= 2 else { return }
            history.record(document.state)
            let bounds = CGRect(x: 0, y: 0, width: document.image.width, height: document.image.height)
            document.cropRect = cropDraft.intersection(bounds).integral
        case .text:
            return
        default:
            guard let draft, isUsable(draft) else { return }
            history.record(document.state)
            document.annotations.append(draft)
        }
    }

    func commitText(_ value: String, at point: CGPoint, width: CGFloat) {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        history.record(document.state)
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
        history.record(document.state)
        document.annotations.remove(at: index)
        self.selectedID = nil
        changed()
    }

    func undo() {
        guard let state = history.undo(current: document.state) else { return }
        document.apply(state)
        selectedID = nil
        changed()
    }

    func redo() {
        guard let state = history.redo(current: document.state) else { return }
        document.apply(state)
        selectedID = nil
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
        case .rectangle, .ellipse, .pixelate:
            let kind: AnnotationKind = tool == .ellipse ? .ellipse : (tool == .pixelate ? .pixelate : .rectangle)
            return Annotation(kind: kind, geometry: .rect(normalizedRect(from: start, to: end)), style: style, zIndex: nextZIndex)
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
        }
    }

    func changed() {
        canvas?.needsDisplay = true
        onChange?()
    }
}
