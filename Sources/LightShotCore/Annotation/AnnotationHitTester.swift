import CoreGraphics

public enum AnnotationHitTester {
    public static func topmost(
        in annotations: [Annotation],
        at point: CGPoint,
        tolerance: CGFloat
    ) -> Annotation? {
        annotations
            .sorted { $0.zIndex > $1.zIndex }
            .first { contains($0, point: point, tolerance: tolerance) }
    }

    public static func contains(_ annotation: Annotation, point: CGPoint, tolerance: CGFloat) -> Bool {
        switch annotation.geometry {
        case .rect(let rect):
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .line(let start, let end):
            return distance(from: point, toSegmentFrom: start, to: end) <= tolerance + annotation.style.lineWidth / 2
        case .path(let points):
            guard points.count > 1 else { return false }
            for index in 1..<points.count {
                if distance(from: point, toSegmentFrom: points[index - 1], to: points[index])
                    <= tolerance + annotation.style.lineWidth / 2 {
                    return true
                }
            }
            return false
        case .text(let origin, let width, _):
            let rect = CGRect(
                x: origin.x,
                y: origin.y,
                width: width,
                height: annotation.style.fontSize * 1.4
            )
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    private static func distance(from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        if dx == 0 && dy == 0 {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / (dx * dx + dy * dy)))
        let projection = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
        return hypot(point.x - projection.x, point.y - projection.y)
    }
}
