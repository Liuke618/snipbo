import CoreGraphics

/// Converts a Vision translational registration into the terms the stitcher
/// needs, and bounds the composite size.
public enum ScrollAlignment {
    /// Pixel budget for the stitched composite (40 Mpx ≈ 160 MiB of RGBA).
    /// Every append reallocates the composite, so an extreme height on a wide
    /// region would multiply that transient; the budget caps the effective
    /// height for wide captures.
    public static let maxCompositePixels = 40_000_000

    /// Vision's translational registration works in a bottom-left, y-up pixel
    /// space. A downward scroll (the page moved up, previous content toward
    /// the bottom of the current frame) yields a negative `translationY` whose
    /// magnitude is the rows of new content at the frame's bottom. Returns the
    /// number of top rows of the current frame that overlap the composite —
    /// the stitcher's `offset` — or nil when the frame must be skipped:
    /// no movement, an upward scroll, or a shift of a whole frame or more,
    /// which cannot be trusted.
    public static func overlapRows(translationY: Int, frameHeight: Int) -> Int? {
        guard translationY < 0, translationY > -frameHeight else { return nil }
        return frameHeight + translationY
    }

    /// Clamps the requested height so `width × height` stays within the
    /// composite pixel budget.
    public static func effectiveMaxHeight(requested: Int, width: Int) -> Int {
        guard width > 0 else { return max(1, requested) }
        return max(1, min(requested, maxCompositePixels / width))
    }
}
