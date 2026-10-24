import CoreGraphics
import Foundation

public struct RGBA: Codable, Equatable, Sendable {
    public var red: CGFloat
    public var green: CGFloat
    public var blue: CGFloat
    public var alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let red = RGBA(red: 1, green: 0, blue: 0)
    public static let yellow = RGBA(red: 1, green: 0.8, blue: 0)
    public static let black = RGBA(red: 0, green: 0, blue: 0)
    public static let white = RGBA(red: 1, green: 1, blue: 1)
}

public enum AnnotationKind: String, Codable, Sendable {
    case arrow, rectangle, ellipse, line, freehand, highlight, text, pixelate
    case blur, spotlight, counter, magnifier
}

public enum AnnotationGeometry: Codable, Equatable, Sendable {
    case rect(CGRect)
    case line(start: CGPoint, end: CGPoint)
    case path(points: [CGPoint])
    case text(origin: CGPoint, width: CGFloat, value: String)
    /// Step-counter badge: the numbered circle's center. `value` is the step
    /// number assigned when the badge was placed.
    case badge(center: CGPoint, value: Int)
    /// Magnifier callout: the lens is drawn at `center`, magnifying the image
    /// around `source`.
    case lens(center: CGPoint, source: CGPoint, radius: CGFloat)
}

public struct AnnotationStyle: Codable, Equatable, Sendable {
    public var color: RGBA
    public var lineWidth: CGFloat
    public var opacity: CGFloat
    public var fontSize: CGFloat
    public var pixelBlockSize: CGFloat

    public init(
        color: RGBA = .red,
        lineWidth: CGFloat = 3,
        opacity: CGFloat = 1,
        fontSize: CGFloat = 24,
        pixelBlockSize: CGFloat = 12
    ) {
        self.color = color
        self.lineWidth = lineWidth
        self.opacity = opacity
        self.fontSize = fontSize
        self.pixelBlockSize = pixelBlockSize
    }
}

public struct Annotation: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var kind: AnnotationKind
    public var geometry: AnnotationGeometry
    public var style: AnnotationStyle
    public var zIndex: Int

    public init(
        id: UUID = UUID(),
        kind: AnnotationKind,
        geometry: AnnotationGeometry,
        style: AnnotationStyle,
        zIndex: Int
    ) {
        self.id = id
        self.kind = kind
        self.geometry = geometry
        self.style = style
        self.zIndex = zIndex
    }

    /// Bounding rect of the geometry in image pixels. Text bounds follow the
    /// 1.4x line height used when rendering; badges and lenses are circles.
    public var bounds: CGRect {
        switch geometry {
        case .rect(let rect):
            return rect
        case .line(let start, let end):
            let bounds = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            // The selection box must cover the arrowhead, which spreads wider
            // than the shaft (~1.7× the line width each side of the tip).
            return bounds.insetBy(dx: -style.lineWidth * 1.3, dy: -style.lineWidth * 1.3)
        case .path(let points):
            guard let first = points.first else { return .zero }
            var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
            for point in points.dropFirst() {
                minX = min(minX, point.x)
                minY = min(minY, point.y)
                maxX = max(maxX, point.x)
                maxY = max(maxY, point.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .text(let origin, let width, _):
            return CGRect(x: origin.x, y: origin.y, width: width, height: style.fontSize * 1.4)
        case .badge(let center, _):
            let diameter = max(24, style.fontSize)
            return CGRect(
                x: center.x - diameter / 2,
                y: center.y - diameter / 2,
                width: diameter,
                height: diameter
            )
        case .lens(let center, _, let radius):
            return CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        }
    }
}

extension AnnotationStyle {
    /// Scales the size-carrying style values by a uniform resize factor;
    /// color and opacity are untouched.
    public func scaled(by factor: CGFloat) -> AnnotationStyle {
        var copy = self
        copy.lineWidth *= factor
        copy.fontSize *= factor
        copy.pixelBlockSize *= factor
        return copy
    }
}

extension AnnotationGeometry {
    /// Scales every coordinate by a uniform resize factor, used when the
    /// document image is resampled so annotations keep their placement.
    public func scaled(by factor: CGFloat) -> AnnotationGeometry {
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * factor, y: p.y * factor) }
        switch self {
        case .rect(let rect):
            return .rect(CGRect(
                x: rect.minX * factor,
                y: rect.minY * factor,
                width: rect.width * factor,
                height: rect.height * factor
            ))
        case .line(let start, let end):
            return .line(start: point(start), end: point(end))
        case .path(let points):
            return .path(points: points.map(point))
        case .text(let origin, let width, let value):
            return .text(origin: point(origin), width: width * factor, value: value)
        case .badge(let center, let value):
            return .badge(center: point(center), value: value)
        case .lens(let center, let source, let radius):
            return .lens(center: point(center), source: point(source), radius: radius * factor)
        }
    }
}
