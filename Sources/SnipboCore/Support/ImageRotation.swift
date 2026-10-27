import CoreGraphics

public enum ImageRotation {
    /// Rotates by 90 degrees. Horizontal scrolling capture feeds rotated frames
    /// through the vertical stitcher and rotates the result back.
    public static func rotated90(_ image: CGImage, clockwise: Bool) -> CGImage? {
        let width = image.height
        let height = image.width
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        if clockwise {
            context.translateBy(x: CGFloat(width), y: 0)
            context.rotate(by: .pi / 2)
        } else {
            context.translateBy(x: 0, y: CGFloat(height))
            context.rotate(by: -.pi / 2)
        }
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        return context.makeImage()
    }
}
