import CoreGraphics

/// Grows a stitched scrolling image without reallocating the whole composite
/// for every frame. Appends copy only the new rows into a preallocated buffer;
/// rows prepended above the composite are kept as small slices and composed
/// once when the capture stops.
///
/// The registration strips are served from two small rolling buffers, seeded
/// from the initial frame and shifted incrementally by `append`/`prepend`, so
/// the full-height main buffer is never copied on the per-frame path.
///
/// Thread confinement: one instance is used from a single serial work queue.
public final class ScrollComposite {
    private let width: Int
    private let maxHeight: Int
    private let colorSpace: CGColorSpace
    private let mainContext: CGContext

    /// Rows in the main (initial + appended) buffer. The buffer is top-aligned.
    private var mainHeight = 0
    /// Prepended slices, topmost first. Each slice is detached from its source
    /// frame so a long upward scroll does not retain every full viewport.
    private var headSlices: [CGImage] = []
    private var headHeight = 0

    /// Rolling registration-strip buffers. Each context holds the first
    /// (`topStripValid`) or last (`bottomStripValid`) rows of the composite,
    /// top-aligned, and is shifted incrementally as rows are prepended or
    /// appended. When a request exceeds what a buffer holds it is rebuilt from
    /// the composite and adopted at the larger size.
    private var topStripContext: CGContext?
    private var topStripValid = 0
    private var bottomStripContext: CGContext?
    private var bottomStripValid = 0

    public private(set) var height = 0
    public private(set) var appendedRows = 0
    public private(set) var reachedLimit = false

    public init?(image: CGImage, maxHeight: Int) {
        guard image.width > 0, image.height > 0, maxHeight > 0 else { return nil }
        self.width = image.width
        self.maxHeight = maxHeight
        self.colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: maxHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        self.mainContext = context
        mainContext.interpolationQuality = .high

        let initialHeight = min(image.height, maxHeight)
        let initial = initialHeight == image.height
            ? image
            : image.cropping(to: CGRect(x: 0, y: 0, width: width, height: initialHeight))
        guard let initial else { return nil }
        draw(initial, atTopRow: 0, in: mainContext, canvasHeight: maxHeight)
        mainHeight = initialHeight
        height = initialHeight
        reachedLimit = initialHeight >= maxHeight

        // Seed both strip buffers from the initial frame: at this point the
        // composite is exactly `initial`, so no copy of the main buffer is
        // needed. Callers request one viewport of rows, which is what the
        // initial frame already is.
        topStripContext = makeStripContext(rows: initialHeight)
        bottomStripContext = makeStripContext(rows: initialHeight)
        if let context = topStripContext {
            draw(initial, atTopRow: 0, in: context, canvasHeight: initialHeight)
            topStripValid = initialHeight
        }
        if let context = bottomStripContext {
            draw(initial, atTopRow: 0, in: context, canvasHeight: initialHeight)
            bottomStripValid = initialHeight
        }
    }

    /// Appends the non-overlapping bottom part of `frame`. `offset` is the
    /// number of top rows in `frame` that overlap the existing image.
    @discardableResult
    public func append(frame: CGImage, offset: Int) -> Bool {
        guard frame.width == width, width > 0,
              offset > 0, offset < frame.height,
              maxHeight > height else {
            return false
        }
        let rows = min(frame.height - offset, maxHeight - height)
        guard rows > 0,
              let slice = frame.cropping(to: CGRect(
                  x: 0,
                  y: offset,
                  width: width,
                  height: rows
              )) else { return false }
        draw(slice, atTopRow: mainHeight, in: mainContext, canvasHeight: maxHeight)
        mainHeight += rows
        height += rows
        appendedRows = rows
        reachedLimit = height >= maxHeight
        rollBottomStrip(with: slice, addedRows: rows)
        return true
    }

    /// Prepends the new top rows of `frame`. When the height budget cannot fit
    /// them all, the rows adjacent to the composite are kept so the stitched
    /// image stays continuous.
    @discardableResult
    public func prepend(frame: CGImage, rows: Int) -> Bool {
        guard frame.width == width, width > 0,
              rows > 0, rows < frame.height,
              maxHeight > height else {
            return false
        }
        let prependRows = min(rows, maxHeight - height)
        guard prependRows > 0,
              let slice = frame.cropping(to: CGRect(
                  x: 0,
                  y: rows - prependRows,
                  width: width,
                  height: prependRows
              )),
              let copied = Self.detachedCopy(slice) else { return false }
        headSlices.insert(copied, at: 0)
        headHeight += prependRows
        height += prependRows
        appendedRows = prependRows
        reachedLimit = height >= maxHeight
        rollTopStrip(with: copied, addedRows: prependRows)
        return true
    }

    /// The top `rows` rows of the composite, for registering an upward scroll.
    public func topStrip(rows: Int) -> CGImage? {
        let stripRows = min(rows, height)
        guard stripRows > 0 else { return nil }
        if let context = topStripContext, topStripValid >= stripRows,
           let image = context.makeImage(),
           let cropped = image.cropping(to: CGRect(
               x: 0, y: 0, width: width, height: stripRows
           )) {
            return cropped
        }
        return rebuildTopStrip(rows: stripRows)
    }

    /// The bottom `rows` rows of the composite, for registering a downward
    /// scroll.
    public func bottomStrip(rows: Int) -> CGImage? {
        let stripRows = min(rows, height)
        guard stripRows > 0 else { return nil }
        if let context = bottomStripContext, bottomStripValid >= stripRows,
           let image = context.makeImage(),
           let cropped = image.cropping(to: CGRect(
               x: 0, y: bottomStripValid - stripRows, width: width, height: stripRows
           )) {
            return cropped
        }
        return rebuildBottomStrip(rows: stripRows)
    }

    /// Composes the final image. This is the only full-height copy; the
    /// per-frame path never allocates one.
    public func makeImage() -> CGImage? {
        guard let mainImage = mainContext.makeImage(),
              let mainUsed = mainImage.cropping(to: CGRect(
                  x: 0, y: 0, width: width, height: mainHeight
              )) else { return nil }
        guard headHeight > 0 else {
            // `mainUsed` still references the preallocated max-height buffer.
            // Copy the used rows once at stop so a short capture does not keep
            // the whole height budget alive.
            guard let compact = CGContext(
                data: nil,
                width: width,
                height: mainHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return mainUsed }
            compact.interpolationQuality = .high
            compact.draw(mainUsed, in: CGRect(
                x: 0, y: 0, width: width, height: mainHeight
            ))
            return compact.makeImage() ?? mainUsed
        }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        var topRow = 0
        for slice in headSlices {
            draw(slice, atTopRow: topRow, in: context, canvasHeight: height)
            topRow += slice.height
        }
        draw(mainUsed, atTopRow: headHeight, in: context, canvasHeight: height)
        return context.makeImage()
    }

    /// Slides the bottom strip buffer down over `addedRows` newly appended
    /// rows: the held rows move up (the oldest drop out once the buffer is
    /// full) and the new rows are drawn into the freed space at the bottom.
    private func rollBottomStrip(with added: CGImage, addedRows: Int) {
        guard let context = bottomStripContext else { return }
        let capacity = context.height
        let valid = bottomStripValid
        let kept = min(valid + addedRows, capacity)
        let drop = valid + addedRows - kept
        if drop > 0, drop < valid {
            guard let shifted = context.makeImage() else {
                bottomStripContext = nil
                bottomStripValid = 0
                return
            }
            draw(shifted, atTopRow: -drop, in: context, canvasHeight: capacity)
        }
        draw(added, atTopRow: kept - addedRows, in: context, canvasHeight: capacity)
        bottomStripValid = kept
    }

    /// Shifts the top strip buffer down below `addedRows` newly prepended rows
    /// and draws them above, so the buffer keeps holding the composite's first
    /// rows.
    private func rollTopStrip(with added: CGImage, addedRows: Int) {
        guard let context = topStripContext else { return }
        let capacity = context.height
        guard let shifted = context.makeImage() else {
            topStripContext = nil
            topStripValid = 0
            return
        }
        draw(shifted, atTopRow: addedRows, in: context, canvasHeight: capacity)
        draw(added, atTopRow: 0, in: context, canvasHeight: capacity)
        topStripValid = min(topStripValid + addedRows, capacity)
    }

    /// Slow path for `topStrip`: recomposes the strip from the head slices and
    /// the main buffer, then adopts the fresh context as the rolling buffer at
    /// the requested size.
    private func rebuildTopStrip(rows stripRows: Int) -> CGImage? {
        guard let context = makeStripContext(rows: stripRows) else { return nil }
        var topRow = 0
        var remaining = stripRows
        for slice in headSlices {
            guard remaining > 0 else { break }
            let take = min(slice.height, remaining)
            guard let part = slice.cropping(to: CGRect(
                x: 0, y: 0, width: width, height: take
            )) else { continue }
            draw(part, atTopRow: topRow, in: context, canvasHeight: stripRows)
            topRow += take
            remaining -= take
        }
        if remaining > 0,
           let mainImage = mainContext.makeImage(),
           let part = mainImage.cropping(to: CGRect(
               x: 0, y: 0, width: width, height: remaining
           )) {
            draw(part, atTopRow: topRow, in: context, canvasHeight: stripRows)
        }
        topStripContext = context
        topStripValid = stripRows
        return context.makeImage()
    }

    /// Slow path for `bottomStrip`, symmetric to `rebuildTopStrip`.
    private func rebuildBottomStrip(rows stripRows: Int) -> CGImage? {
        guard let context = makeStripContext(rows: stripRows) else { return nil }
        var placed = 0
        var remaining = stripRows

        let mainTake = min(mainHeight, remaining)
        if mainTake > 0,
           let mainImage = mainContext.makeImage(),
           let part = mainImage.cropping(to: CGRect(
               x: 0, y: mainHeight - mainTake, width: width, height: mainTake
           )) {
            draw(
                part,
                atTopRow: stripRows - mainTake,
                in: context,
                canvasHeight: stripRows
            )
            placed += mainTake
            remaining -= mainTake
        }

        for slice in headSlices.reversed() {
            guard remaining > 0 else { break }
            let take = min(slice.height, remaining)
            guard let part = slice.cropping(to: CGRect(
                x: 0, y: slice.height - take, width: width, height: take
            )) else { continue }
            draw(
                part,
                atTopRow: stripRows - placed - take,
                in: context,
                canvasHeight: stripRows
            )
            placed += take
            remaining -= take
        }
        bottomStripContext = context
        bottomStripValid = stripRows
        return context.makeImage()
    }

    private func makeStripContext(rows: Int) -> CGContext? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: rows,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        return context
    }

    private func draw(
        _ image: CGImage,
        atTopRow topRow: Int,
        in context: CGContext,
        canvasHeight: Int
    ) {
        let y = canvasHeight - topRow - image.height
        context.draw(image, in: CGRect(
            x: 0, y: y, width: image.width, height: image.height
        ))
    }

    private static func detachedCopy(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(
            x: 0, y: 0, width: image.width, height: image.height
        ))
        return context.makeImage()
    }
}
