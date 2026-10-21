import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageExporter {
    public static func pngData(from image: CGImage) -> Data? {
        encode(image, type: UTType.png.identifier as CFString, options: nil)
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
