import CoreGraphics
import Foundation

/// Alpha-boundary cropping for window captures.
public enum ImageTrimming {
    /// Crops away fully transparent margins (a window screenshot's shadow
    /// padding). Returns nil when there is nothing to trim: the image has no
    /// alpha channel, is fully opaque, is fully transparent, or the bounds
    /// already equal the full rect.
    public static func trimmedToOpaqueBounds(_ image: CGImage) -> CGImage? {
        guard image.alphaInfo != .none && image.alphaInfo != .noneSkipLast else { return nil }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let rowBase = y * width * 4
            for x in 0..<width {
                if bytes[rowBase + x * 4 + 3] > 0 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        guard minX > 0 || minY > 0 || maxX < width - 1 || maxY < height - 1 else { return nil }

        // Memory rows are top-down; cropping uses image (top-left) coordinates.
        return image.cropping(to: CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        ))
    }
}
