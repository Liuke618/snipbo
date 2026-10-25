import CoreGraphics

/// Converts a Vision translational registration into the terms the stitcher
/// needs, and bounds the composite size.
public enum ScrollAlignment {
    /// Pixel budget for the stitched composite (40 Mpx ≈ 160 MiB of RGBA).
    /// Every append reallocates the composite, so an extreme height on a wide
    /// region would multiply that transient; the budget caps the effective
    /// height for wide captures.
    public static let maxCompositePixels = 40_000_000

    /// The stitching reference is the composite's bottom strip — the live
    /// frontier — not the previous frame. Vision registers that strip against
    /// the new frame; scrolling down moves the strip's content UP in the
    /// frame, so a downward scroll yields a POSITIVE `translationY` whose
    /// magnitude is the rows of new content at the frame's bottom. Returns
    /// the number of top rows of the frame to skip so the append starts
    /// exactly at the composite's bottom edge, or nil when the frame adds
    /// nothing and must be skipped: no movement, an upward scroll, or a jump
    /// of a whole strip or more, which cannot be trusted.
    public static func frontierSkipRows(
        translationY: Int,
        stripHeight: Int,
        frameHeight: Int
    ) -> Int? {
        guard translationY > 0, translationY < stripHeight else { return nil }
        return stripHeight - translationY
    }

    /// The leading rows a frame contributes above the composite, from a
    /// registration against the composite's TOP strip. Scrolling up moves the
    /// strip's content DOWN in the new frame, so `translationY` is negative and
    /// its magnitude is the rows of new content at the frame's top. Returns nil
    /// for no movement, a downward scroll, or a jump of a whole strip or more.
    public static func leadingRows(
        translationY: Int,
        stripHeight: Int,
        frameHeight: Int
    ) -> Int? {
        guard translationY < 0 else { return nil }
        let rows = -translationY
        guard rows > 0, rows < stripHeight else { return nil }
        return rows
    }

    /// Clamps the requested height so `width × height` stays within the
    /// composite pixel budget.
    public static func effectiveMaxHeight(requested: Int, width: Int) -> Int {
        guard width > 0 else { return max(1, requested) }
        return max(1, min(requested, maxCompositePixels / width))
    }
}
