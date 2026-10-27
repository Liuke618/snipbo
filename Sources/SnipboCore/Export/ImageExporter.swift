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
        return resampled(image, to: CGSize(width: width, height: height))
    }

    /// Resamples to an exact pixel size with high-quality interpolation.
    /// Returns the original image for degenerate targets or when rendering
    /// fails.
    public static func resampled(_ image: CGImage, to target: CGSize) -> CGImage {
        let width = max(1, Int(target.width.rounded()))
        let height = max(1, Int(target.height.rounded()))
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
        lossyData(
            image,
            type: UTType.jpeg.identifier as CFString,
            quality: quality,
            targetBytes: nil,
            flattenAlpha: true
        )
    }

    public static func heicData(from image: CGImage, quality: CGFloat) -> Data? {
        lossyData(
            image,
            type: UTType.heic.identifier as CFString,
            quality: quality,
            targetBytes: nil,
            flattenAlpha: false
        )
    }

    public static func avifData(from image: CGImage, quality: CGFloat) -> Data? {
        let type = UTType("public.avif")?.identifier ?? UTType.heic.identifier
        return lossyData(
            image,
            type: type as CFString,
            quality: quality,
            targetBytes: nil,
            flattenAlpha: false
        )
    }

    /// Encodes according to the chosen format. For lossy formats a non-zero
    /// `targetBytes` lowers the quality until the output fits, keeping the
    /// highest quality that satisfies the budget.
    public static func data(
        from image: CGImage,
        format: ImageFormat,
        quality: Double,
        targetBytes: Int? = nil
    ) -> Data? {
        switch format {
        case .png:
            return pngData(from: image)
        case .jpeg:
            return lossyData(
                image,
                type: UTType.jpeg.identifier as CFString,
                quality: quality,
                targetBytes: targetBytes,
                flattenAlpha: true
            )
        case .heic:
            return lossyData(
                image,
                type: UTType.heic.identifier as CFString,
                quality: quality,
                targetBytes: targetBytes,
                flattenAlpha: false
            )
        case .avif:
            let type = UTType("public.avif")?.identifier ?? UTType.heic.identifier
            return lossyData(
                image,
                type: type as CFString,
                quality: quality,
                targetBytes: targetBytes,
                flattenAlpha: false
            )
        }
    }

    private static func lossyData(
        _ image: CGImage,
        type: CFString,
        quality: CGFloat,
        targetBytes: Int?,
        flattenAlpha: Bool
    ) -> Data? {
        func encoded(quality: CGFloat) -> Data? {
            let source = flattenAlpha ? flattened(image) : image
            return encode(
                source ?? image,
                type: type,
                options: [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
            )
        }
        guard let targetBytes, targetBytes > 0 else {
            return encoded(quality: quality)
        }
        var low: CGFloat = 0.05
        var high: CGFloat = 1
        var best: Data?
        for _ in 0..<9 {
            let mid = (low + high) / 2
            guard let data = encoded(quality: mid) else { break }
            if data.count <= targetBytes {
                best = data
                low = mid
            } else {
                high = mid
            }
        }
        return best ?? encoded(quality: 0.05)
    }

    /// JPEG cannot carry alpha; composite onto sRGB so the encoder sees a
    /// 24-bit image instead of failing or producing a black background.
    private static func flattened(_ image: CGImage) -> CGImage? {
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
        return context.makeImage()
    }

    private static func encode(_ image: CGImage, type: CFString, options: CFDictionary?) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
