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
}
