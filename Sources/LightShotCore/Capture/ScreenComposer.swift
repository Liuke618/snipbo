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

public enum ScreenComposer {
    /// Composes displays into one image using their AppKit-global arrangement.
    /// The output uses the largest backing scale so no screen is downsampled.
    public static func compose(_ slices: [ScreenSlice]) -> CGImage? {
        guard let first = slices.first else { return nil }
        let union = slices.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        let scale = slices.map(\.backingScale).max() ?? 1
        guard union.width > 0, union.height > 0, scale > 0 else { return nil }

        let width = Int((union.width * scale).rounded(.up))
        let height = Int((union.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(
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
        return context.makeImage()
    }
}
