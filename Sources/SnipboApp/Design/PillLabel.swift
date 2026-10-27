import AppKit

/// Draws a capsule tag (capture size readout, window-picker title). Fixed
/// white-on-black so it stays legible over any screenshot content.
@MainActor
enum PillLabel {
    static let padding = NSSize(width: 8, height: 2)

    static func attributes(foreground: NSColor = .white) -> [NSAttributedString.Key: Any] {
        [.font: DesignTokens.readoutFont, .foregroundColor: foreground]
    }

    static func size(for text: String) -> NSSize {
        let textSize = (text as NSString).size(withAttributes: attributes())
        return NSSize(
            width: textSize.width + padding.width * 2,
            height: textSize.height + padding.height * 2
        )
    }

    /// Draws the capsule and its text at `origin`. The origin follows the
    /// current view's flipped state, like any NSString draw call.
    static func draw(_ text: String, at origin: CGPoint) {
        let size = size(for: text)
        let rect = CGRect(origin: origin, size: size)
        let capsule = NSBezierPath(
            roundedRect: rect,
            xRadius: size.height / 2,
            yRadius: size.height / 2
        )
        DesignTokens.overlayFill.setFill()
        capsule.fill()
        (text as NSString).draw(
            at: CGPoint(x: origin.x + padding.width, y: origin.y + padding.height),
            withAttributes: attributes()
        )
    }
}
