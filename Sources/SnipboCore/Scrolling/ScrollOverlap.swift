import CoreGraphics

/// Verifies that a registration's overlap really exists in both images.
///
/// Vision returns a confident translational match even when the reference
/// strip is not in the candidate frame (repeated chat layouts are a common
/// trigger), so `confidence` alone cannot gate stitching. This compares the
/// implied overlap structurally: strong edges must coincide within one pixel,
/// which tolerates subpixel scroll resampling but rejects unrelated content.
public enum ScrollOverlap {
    /// Below this many overlapping rows a match is too small to trust.
    public static let minimumRows = 48
    /// Fraction of sampled edges allowed to have no counterpart. True overlaps
    /// measure near 0 (≈0.006 with subpixel resampling); repeated-layout false
    /// matches measure ≥≈0.025.
    public static let maximumEdgeMismatch = 0.015
    /// Too few edges means blank content, where an overlap cannot be verified.
    private static let minimumSampledEdges = 32

    /// `compositeRowOffset` and `frameRowOffset` mark the first row of the
    /// overlapping region in each image; both regions span `rows` rows.
    public static func confidentlyOverlaps(
        composite: CGImage,
        frame: CGImage,
        compositeRowOffset: Int,
        frameRowOffset: Int,
        rows: Int
    ) -> Bool {
        guard let mismatch = edgeMismatch(
            composite: composite,
            frame: frame,
            compositeRowOffset: compositeRowOffset,
            frameRowOffset: frameRowOffset,
            rows: rows
        ) else { return false }
        return mismatch <= maximumEdgeMismatch
    }

    /// Fraction of strong edges in the overlap with no edge within one pixel
    /// in the other image, or nil when the regions are invalid or too blank.
    static func edgeMismatch(
        composite: CGImage,
        frame: CGImage,
        compositeRowOffset: Int,
        frameRowOffset: Int,
        rows: Int
    ) -> Double? {
        guard rows >= minimumRows,
              compositeRowOffset >= 0,
              frameRowOffset >= 0,
              compositeRowOffset + rows <= composite.height,
              frameRowOffset + rows <= frame.height,
              composite.width == frame.width,
              let a = grayRows(composite, top: compositeRowOffset, rows: rows),
              let b = grayRows(frame, top: frameRowOffset, rows: rows) else {
            return nil
        }

        var edgeCount = 0
        var unmatched = 0
        // Step by two pixels: text and UI edges are far denser than that.
        for y in stride(from: 1, to: rows - 1, by: 2) {
            for x in stride(from: 1, to: a.width - 1, by: 2) {
                let edgeInA = isEdge(a, x: x, y: y)
                let edgeInB = isEdge(b, x: x, y: y)
                guard edgeInA || edgeInB else { continue }
                edgeCount += 1
                let counterpartPresent = edgeInA && edgeInB
                    || (edgeInA ? hasEdgeNear(b, x: x, y: y) : hasEdgeNear(a, x: x, y: y))
                if !counterpartPresent { unmatched += 1 }
            }
        }
        guard edgeCount >= minimumSampledEdges else { return nil }
        return Double(unmatched) / Double(edgeCount)
    }

    private struct GrayRows {
        let data: [UInt8]
        let width: Int
        let rows: Int
    }

    private static func grayRows(_ image: CGImage, top: Int, rows: Int) -> GrayRows? {
        guard let slice = image.cropping(to: CGRect(
            x: 0,
            y: top,
            width: image.width,
            height: rows
        )) else { return nil }
        var data = [UInt8](repeating: 0, count: image.width * rows)
        guard let context = CGContext(
            data: &data,
            width: image.width,
            height: rows,
            bitsPerComponent: 8,
            bytesPerRow: image.width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.draw(slice, in: CGRect(x: 0, y: 0, width: image.width, height: rows))
        return GrayRows(data: data, width: image.width, rows: rows)
    }

    private static func isEdge(_ gray: GrayRows, x: Int, y: Int) -> Bool {
        let index = y * gray.width + x
        var delta = 0
        if x + 2 < gray.width {
            delta = max(delta, abs(Int(gray.data[index]) - Int(gray.data[index + 2])))
        }
        if y + 2 < gray.rows {
            delta = max(delta, abs(Int(gray.data[index]) - Int(gray.data[index + 2 * gray.width])))
        }
        return delta > 24
    }

    private static func hasEdgeNear(_ gray: GrayRows, x: Int, y: Int) -> Bool {
        for dy in -1...1 {
            for dx in -1...1 {
                let xx = x + dx
                let yy = y + dy
                if xx >= 0, yy >= 0, xx < gray.width, yy < gray.rows, isEdge(gray, x: xx, y: yy) {
                    return true
                }
            }
        }
        return false
    }
}
