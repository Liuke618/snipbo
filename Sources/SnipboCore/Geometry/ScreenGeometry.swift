import CoreGraphics

public struct ScreenGeometry: Equatable, Sendable {
    public let displayID: CGDirectDisplayID
    public let frame: CGRect
    public let backingScale: CGFloat

    public init(displayID: CGDirectDisplayID, frame: CGRect, backingScale: CGFloat) {
        self.displayID = displayID
        self.frame = frame
        self.backingScale = backingScale
    }

    public func pixelRect(fromLocalPoints rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX * backingScale,
            y: rect.minY * backingScale,
            width: rect.width * backingScale,
            height: rect.height * backingScale
        ).integral
    }

    public func localPointRect(fromPixelRect rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX / backingScale,
            y: rect.minY / backingScale,
            width: rect.width / backingScale,
            height: rect.height / backingScale
        )
    }

    public func clampedLocalPoints(_ rect: CGRect) -> CGRect {
        rect.intersection(CGRect(origin: .zero, size: frame.size))
    }
}
