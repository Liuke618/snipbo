import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageExporter {
    public static func pngData(from image: CGImage) -> Data? {
        encode(image, type: UTType.png.identifier as CFString, options: nil)
    }

    /// Downscales by `factor` with high-quality interpolation. Returns the
    /// original image unchanged for out-of-range factors or degenerate sizes.
    public static func downscaled(_ image: CGImage, by factor: CGFloat) -> CGImage {
        guard factor > 0, factor < 1 else { return image }
        let width = max(1, Int((CGFloat(image.width) * factor).rounded()))
        let height = max(1, Int((CGFloat(image.height) * factor).rounded()))
        guard width != image.width || height != image.height else { return image }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    public static func jpegData(from image: CGImage, quality: CGFloat) -> Data? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let converted = context.makeImage() else { return nil }
        return encode(
            converted,
            type: UTType.jpeg.identifier as CFString,
            options: [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
    }

    private static func encode(_ image: CGImage, type: CFString, options: CFDictionary?) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
