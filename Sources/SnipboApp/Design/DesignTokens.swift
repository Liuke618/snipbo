import AppKit

/// Shared visual constants for the unified system-native look. Views must not
/// invent their own corner radii, spacings, or alpha levels — every value here
/// comes from the design token table.
@MainActor
enum DesignTokens {
    enum Radius {
        static let control: CGFloat = 6
        static let card: CGFloat = 8
        static let panel: CGFloat = 10
        static let pill: CGFloat = 999
    }

    enum Spacing {
        static let icon: CGFloat = 4
        static let tight: CGFloat = 8
        static let panelInset: CGFloat = 12
        static let section: CGFloat = 16
    }

    enum Alpha {
        static let hover: CGFloat = 0.07
        static let selected: CGFloat = 0.14
        static let pressed: CGFloat = 0.22
        /// Capsule buttons on dark HUD surfaces.
        static let pillOnDark: CGFloat = 0.16
        /// Capsule press on dark HUD surfaces.
        static let pillPress: CGFloat = 0.28
    }

    enum Shadow {
        static let panelOpacity: Float = 0.28
        static let panelRadius: CGFloat = 12
        static let cardOpacity: Float = 0.06
        static let cardRadius: CGFloat = 2
        static let cardHoverOpacity: Float = 0.13
        static let cardHoverRadius: CGFloat = 14
    }

    /// Fixed white/black for overlays drawn on top of screenshot content; these
    /// intentionally do not follow the system appearance.
    static let overlayDim: CGFloat = 0.45
    static let overlayFill = NSColor.black.withAlphaComponent(0.72)

    static let readoutFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    static let controlFont = NSFont.systemFont(ofSize: 12)
    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
}
