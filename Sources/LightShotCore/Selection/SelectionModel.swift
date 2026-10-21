import CoreGraphics

public enum SelectionHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, inside
}

public struct SelectionModel: Equatable, Sendable {
    public private(set) var rect: CGRect
    public let minimumSize: CGFloat

    public init(rect: CGRect = .zero, minimumSize: CGFloat = 1) {
        self.rect = rect
        self.minimumSize = minimumSize
    }

    public var isUsable: Bool {
        rect.width >= minimumSize && rect.height >= minimumSize
    }

    public func handle(at point: CGPoint, tolerance: CGFloat) -> SelectionHandle? {
        let expanded = rect.insetBy(dx: -tolerance, dy: -tolerance)
        guard expanded.contains(point) else { return nil }

        let corners: [(SelectionHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
        ]
        for (handle, corner) in corners where hypot(point.x - corner.x, point.y - corner.y) <= tolerance {
            return handle
        }

        if abs(point.y - rect.minY) <= tolerance { return .top }
        if abs(point.y - rect.maxY) <= tolerance { return .bottom }
        if abs(point.x - rect.minX) <= tolerance { return .left }
        if abs(point.x - rect.maxX) <= tolerance { return .right }
        return rect.contains(point) ? .inside : nil
    }

    public mutating func drag(handle: SelectionHandle, to point: CGPoint, constrainedTo bounds: CGRect) {
        let clampedPoint = CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )

        switch handle {
        case .inside:
            let dx = clampedPoint.x - rect.midX
            let dy = clampedPoint.y - rect.midY
            var moved = rect.offsetBy(dx: dx, dy: dy)
            moved.origin.x = min(max(moved.origin.x, bounds.minX), bounds.maxX - moved.width)
            moved.origin.y = min(max(moved.origin.y, bounds.minY), bounds.maxY - moved.height)
            rect = moved
        case .topLeft:
            rect = CGRect(
                x: clampedPoint.x,
                y: clampedPoint.y,
                width: max(minimumSize, rect.maxX - clampedPoint.x),
                height: max(minimumSize, rect.maxY - clampedPoint.y)
            )
        case .top:
            rect = CGRect(
                x: rect.minX,
                y: clampedPoint.y,
                width: rect.width,
                height: max(minimumSize, rect.maxY - clampedPoint.y)
            )
        case .topRight:
            rect = CGRect(
                x: rect.minX,
                y: clampedPoint.y,
                width: max(minimumSize, clampedPoint.x - rect.minX),
                height: max(minimumSize, rect.maxY - clampedPoint.y)
            )
        case .right:
            rect = CGRect(
                x: rect.minX,
                y: rect.minY,
                width: max(minimumSize, clampedPoint.x - rect.minX),
                height: rect.height
            )
        case .bottomRight:
            rect = CGRect(
                x: rect.minX,
                y: rect.minY,
                width: max(minimumSize, clampedPoint.x - rect.minX),
                height: max(minimumSize, clampedPoint.y - rect.minY)
            )
        case .bottom:
            rect = CGRect(
                x: rect.minX,
                y: rect.minY,
                width: rect.width,
                height: max(minimumSize, clampedPoint.y - rect.minY)
            )
        case .bottomLeft:
            rect = CGRect(
                x: clampedPoint.x,
                y: rect.minY,
                width: max(minimumSize, rect.maxX - clampedPoint.x),
                height: max(minimumSize, clampedPoint.y - rect.minY)
            )
        case .left:
            rect = CGRect(
                x: clampedPoint.x,
                y: rect.minY,
                width: max(minimumSize, rect.maxX - clampedPoint.x),
                height: rect.height
            )
        }

        clampToBounds(bounds)
    }

    public mutating func nudge(dx: CGFloat, dy: CGFloat, resize: Bool, constrainedTo bounds: CGRect) {
        if resize {
            rect.size.width = min(bounds.maxX - rect.minX, max(minimumSize, rect.width + dx))
            rect.size.height = min(bounds.maxY - rect.minY, max(minimumSize, rect.height + dy))
        } else {
            rect.origin.x = min(max(rect.origin.x + dx, bounds.minX), bounds.maxX - rect.width)
            rect.origin.y = min(max(rect.origin.y + dy, bounds.minY), bounds.maxY - rect.height)
        }

        clampToBounds(bounds)
    }

    private mutating func clampToBounds(_ bounds: CGRect) {
        var clamped = rect
        clamped.size.width = min(max(clamped.width, minimumSize), bounds.width)
        clamped.size.height = min(max(clamped.height, minimumSize), bounds.height)
        clamped.origin.x = min(max(clamped.origin.x, bounds.minX), bounds.maxX - clamped.width)
        clamped.origin.y = min(max(clamped.origin.y, bounds.minY), bounds.maxY - clamped.height)
        rect = clamped
    }
}
