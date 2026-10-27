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
            let reach = annotation.kind == .pixelateBrush
                ? annotation.style.lineWidth * 3
                : annotation.style.lineWidth / 2
            for index in 1..<points.count {
                if distance(from: point, toSegmentFrom: points[index - 1], to: points[index])
                    <= tolerance + reach {
                    return true
                }
            }
            return false
        case .polygon(let points):
            guard points.count >= 3 else { return false }
            if polygonContains(point, points) { return true }
            for index in points.indices {
                let next = points[(index + 1) % points.count]
                if distance(from: point, toSegmentFrom: points[index], to: next)
                    <= tolerance + annotation.style.lineWidth / 2 {
                    return true
                }
            }
            return false
        case .text:
            return annotation.bounds
                .insetBy(dx: -tolerance, dy: -tolerance)
                .contains(point)
        case .badge(let center, _):
            let diameter = max(24, annotation.style.fontSize)
            return CGRect(
                x: center.x - diameter / 2 - tolerance,
                y: center.y - diameter / 2 - tolerance,
                width: diameter + tolerance * 2,
                height: diameter + tolerance * 2
            ).contains(point)
        case .lens(let center, _, let radius):
            return hypot(point.x - center.x, point.y - center.y) <= radius + tolerance
        }
    }

    private static func polygonContains(
        _ point: CGPoint,
        _ polygon: [CGPoint]
    ) -> Bool {
        var inside = false
        var previous = polygon[polygon.count - 1]
        for current in polygon {
            let crosses = (current.y > point.y) != (previous.y > point.y)
            if crosses {
                let x = (previous.x - current.x)
                    * (point.y - current.y)
                    / (previous.y - current.y)
                    + current.x
                if point.x < x { inside.toggle() }
            }
            previous = current
        }
        return inside
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
