import CoreGraphics

public struct ScrollStitchResult {
    public let image: CGImage
    public let appendedRows: Int
    public let reachedLimit: Bool

    public init(image: CGImage, appendedRows: Int, reachedLimit: Bool) {
        self.image = image
        self.appendedRows = appendedRows
        self.reachedLimit = reachedLimit
    }
}

public enum ScrollStitcher {
    /// Prepares the first frame, cropping it if it already exceeds the limit.
    public static func makeInitial(image: CGImage, maxHeight: Int) -> ScrollStitchResult? {
        guard image.width > 0, image.height > 0, maxHeight > 0 else { return nil }
        let height = min(image.height, maxHeight)
        if height == image.height {
            return ScrollStitchResult(
                image: image,
                appendedRows: 0,
                reachedLimit: image.height >= maxHeight
            )
        }
        guard let cropped = image.cropping(to: CGRect(
            x: 0,
            y: 0,
            width: image.width,
            height: height
        )) else { return nil }
        return ScrollStitchResult(image: cropped, appendedRows: 0, reachedLimit: true)
    }

    /// Appends the non-overlapping bottom part of `frame` to `composite`.
    /// `offset` is the number of top rows in `frame` that overlap the existing
    /// image (positive when the page scrolled down).
    public static func append(
        composite: CGImage,
        frame: CGImage,
        offset: Int,
        maxHeight: Int
    ) -> ScrollStitchResult? {
        guard composite.width == frame.width,
              composite.width > 0,
              offset > 0,
              offset < frame.height,
              maxHeight > composite.height else {
            return nil
        }
        let appendRows = min(frame.height - offset, maxHeight - composite.height)
        guard appendRows > 0,
              let slice = frame.cropping(to: CGRect(
                  x: 0,
                  y: offset,
                  width: frame.width,
                  height: appendRows
              )) else { return nil }

        let width = composite.width
        let height = composite.height + appendRows
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: composite.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(slice, in: CGRect(x: 0, y: 0, width: width, height: appendRows))
        context.draw(composite, in: CGRect(
            x: 0,
            y: appendRows,
            width: width,
            height: composite.height
        ))
        guard let image = context.makeImage() else { return nil }
        return ScrollStitchResult(
            image: image,
            appendedRows: appendRows,
            reachedLimit: height >= maxHeight
        )
    }

    /// Prepends the new top part of `frame` above `composite`. `rows` is the
    /// number of new rows at the frame's top. When the height budget cannot
    /// fit them all, the rows adjacent to the composite are kept so the
    /// stitched image stays continuous.
    public static func prepend(
        composite: CGImage,
        frame: CGImage,
        rows: Int,
        maxHeight: Int
    ) -> ScrollStitchResult? {
        guard composite.width == frame.width,
              composite.width > 0,
              rows > 0,
              rows < frame.height,
              maxHeight > composite.height else {
            return nil
        }
        let prependRows = min(rows, maxHeight - composite.height)
        guard prependRows > 0,
              let slice = frame.cropping(to: CGRect(
                  x: 0,
                  y: rows - prependRows,
                  width: frame.width,
                  height: prependRows
              )) else { return nil }

        let width = composite.width
        let height = composite.height + prependRows
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: composite.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(slice, in: CGRect(x: 0, y: composite.height, width: width, height: prependRows))
        context.draw(composite, in: CGRect(
            x: 0,
            y: 0,
            width: width,
            height: composite.height
        ))
        guard let image = context.makeImage() else { return nil }
        return ScrollStitchResult(
            image: image,
            appendedRows: prependRows,
            reachedLimit: height >= maxHeight
        )
    }
}
