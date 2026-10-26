import CoreGraphics

public struct ScreenSlice: @unchecked Sendable {
    public let image: CGImage
    /// AppKit-global points, bottom-left origin.
    public let frame: CGRect
    public let backingScale: CGFloat

    public init(image: CGImage, frame: CGRect, backingScale: CGFloat) {
        self.image = image
        self.frame = frame
        self.backingScale = backingScale
    }
}

public struct ScreenComposition: @unchecked Sendable {
    public let image: CGImage
    public let scale: CGFloat

    public init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
    }
}

public enum ScreenComposer {
    /// Pixel budget for the composed image (64 Mpx ≈ 256 MiB of RGBA).
    public static let maxCompositePixels = 64_000_000

    /// The output scale that keeps the arrangement within the pixel budget.
    public static func effectiveScale(
        forUnion union: CGRect,
        maxBackingScale: CGFloat,
        pixelBudget: Int = maxCompositePixels
    ) -> CGFloat {
        guard union.width > 0, union.height > 0, maxBackingScale > 0, pixelBudget > 0 else {
            return 1
        }
        let area = union.width * union.height
        let maxScaleByBudget = sqrt(CGFloat(pixelBudget) / area)
        return max(0.01, min(maxBackingScale, maxScaleByBudget))
    }

    /// Composes displays into one image and reports the scale actually used.
    /// The scale is the largest backing scale unless the pixel budget forces a
    /// smaller output, which keeps very large arrangements from exhausting
    /// memory.
    public static func composeWithScale(
        _ slices: [ScreenSlice],
        pixelBudget: Int = maxCompositePixels
    ) -> ScreenComposition? {
        guard let first = slices.first else { return nil }
        let union = slices.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        let maxScale = slices.map(\.backingScale).max() ?? 1
        guard union.width > 0, union.height > 0, maxScale > 0 else { return nil }

        let scale = effectiveScale(
            forUnion: union,
            maxBackingScale: maxScale,
            pixelBudget: pixelBudget
        )
        let width = max(1, Int((union.width * scale).rounded(.up)))
        let height = max(1, Int((union.height * scale).rounded(.up)))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        for slice in slices {
            // The context is bottom-left based like AppKit-global coordinates,
            // so each slice keeps its relative position after subtracting the
            // union origin.
            let destination = CGRect(
                x: (slice.frame.minX - union.minX) * scale,
                y: (slice.frame.minY - union.minY) * scale,
                width: slice.frame.width * scale,
                height: slice.frame.height * scale
            ).integral
            context.draw(slice.image, in: destination)
        }
        guard let image = context.makeImage() else { return nil }
        return ScreenComposition(image: image, scale: scale)
    }

    /// Composes displays into one image using their AppKit-global arrangement.
    public static func compose(_ slices: [ScreenSlice]) -> CGImage? {
        composeWithScale(slices)?.image
    }
}
