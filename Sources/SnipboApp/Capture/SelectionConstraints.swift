import CoreGraphics

enum ScrollAxis: Sendable {
    case vertical
    case horizontal
}

/// Region-selection behavior configured in Settings. The overlay applies these
/// to new drags and to handle resizing.
struct SelectionConstraints: Equatable, Sendable {
    /// Both dimensions must be non-zero to lock the size of new selections.
    var fixedSize: CGSize?
    var aspectRatio: CGFloat?
    var snapToWindows: Bool

    init(
        fixedSize: CGSize? = nil,
        aspectRatio: CGFloat? = nil,
        snapToWindows: Bool = false
    ) {
        self.fixedSize = fixedSize
        self.aspectRatio = aspectRatio
        self.snapToWindows = snapToWindows
    }
}
