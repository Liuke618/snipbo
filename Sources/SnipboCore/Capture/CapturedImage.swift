import CoreGraphics
import Foundation

public struct CapturedImage: @unchecked Sendable {
    public let image: CGImage
    public let geometry: ScreenGeometry
    public let capturedAt: Date

    public init(image: CGImage, geometry: ScreenGeometry, capturedAt: Date = Date()) {
        self.image = image
        self.geometry = geometry
        self.capturedAt = capturedAt
    }

    public func cropped(toLocalPoints rect: CGRect) -> CGImage? {
        let pixels = geometry.pixelRect(fromLocalPoints: rect)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clamped = pixels.intersection(bounds).integral
        guard clamped.width >= 1, clamped.height >= 1 else { return nil }
        return image.cropping(to: clamped)
    }
}
