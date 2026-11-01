import CoreGraphics
import CoreText
import Foundation

/// Layout shared by the renderer, selection bounds, and hit testing so a
/// multi-line text annotation is measured exactly the way it is drawn.
public enum TextLayout {
    /// Cache key for `size`: every input that can change the measured size.
    /// Annotations are value types, so any change produces a new key and a
    /// stale hit is impossible.
    private final class SizeKey: NSObject {
        let value: String
        let width: CGFloat
        let fontSize: CGFloat
        let fontName: String?
        let fontBold: Bool?
        let textAlignment: AnnotationTextAlignment?

        init(value: String, width: CGFloat, style: AnnotationStyle) {
            self.value = value
            self.width = width
            self.fontSize = style.fontSize
            self.fontName = style.fontName
            self.fontBold = style.fontBold
            self.textAlignment = style.textAlignment
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? SizeKey else { return false }
            return value == other.value
                && width == other.width
                && fontSize == other.fontSize
                && fontName == other.fontName
                && fontBold == other.fontBold
                && textAlignment == other.textAlignment
        }

        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(value)
            hasher.combine(width)
            hasher.combine(fontSize)
            hasher.combine(fontName)
            hasher.combine(fontBold)
            hasher.combine(textAlignment)
            return hasher.finalize()
        }
    }

    /// Memoized `size` results. Bounds are read for hit-testing, selection
    /// boxes, and alignment on every frame; without the cache each read
    /// rebuilds attributed text and a CTFramesetter.
    nonisolated(unsafe) private static let sizeCache: NSCache<SizeKey, NSValue> = {
        let cache = NSCache<SizeKey, NSValue>()
        cache.countLimit = 1024
        return cache
    }()

    public static func attributedString(
        _ value: String,
        width: CGFloat,
        style: AnnotationStyle
    ) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(for: style),
        ]
        attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] =
            CGColor(red: style.color.red, green: style.color.green, blue: style.color.blue, alpha: 1)
        attributes[NSAttributedString.Key(kCTParagraphStyleAttributeName as String)] =
            paragraphStyle(alignment: style.textAlignment ?? .left)
        if let outline = style.textOutline {
            attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] =
                CGColor(red: outline.red, green: outline.green, blue: outline.blue, alpha: 1)
            // Negative width fills and strokes; the magnitude is a percentage
            // of the font size, so the outline stays proportional at any size.
            attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -4.0
        }
        return NSAttributedString(string: value, attributes: attributes)
    }

    public static func size(
        value: String,
        width: CGFloat,
        style: AnnotationStyle
    ) -> CGSize {
        let resolvedWidth = max(1, width)
        let lineHeight = style.fontSize * 1.4
        guard !value.isEmpty else {
            return CGSize(width: resolvedWidth, height: lineHeight)
        }
        let key = SizeKey(value: value, width: resolvedWidth, style: style)
        if let cached = sizeCache.object(forKey: key) {
            return cached.sizeValue
        }
        let attributed = attributedString(value, width: resolvedWidth, style: style)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRangeMake(0, 0),
            nil,
            CGSize(width: resolvedWidth, height: .greatestFiniteMagnitude),
            nil
        )
        let size = CGSize(
            width: resolvedWidth,
            height: max(lineHeight, ceil(suggested.height))
        )
        sizeCache.setObject(NSValue(size: size), forKey: key)
        return size
    }

    public static func font(for style: AnnotationStyle) -> CTFont {
        let size = max(1, style.fontSize)
        let base: CTFont
        if let name = style.fontName, !name.isEmpty {
            base = CTFontCreateWithName(name as CFString, size, nil)
        } else {
            base = CTFontCreateUIFontForLanguage(.system, size, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        }
        guard style.fontBold == true else { return base }
        return CTFontCreateCopyWithSymbolicTraits(
            base,
            size,
            nil,
            .boldTrait,
            .boldTrait
        ) ?? base
    }

    private static func paragraphStyle(
        alignment: AnnotationTextAlignment
    ) -> CTParagraphStyle {
        var value: CTTextAlignment
        switch alignment {
        case .left: value = .left
        case .center: value = .center
        case .right: value = .right
        }
        return withUnsafePointer(to: &value) { pointer in
            let settings = [
                CTParagraphStyleSetting(
                    spec: .alignment,
                    valueSize: MemoryLayout<CTTextAlignment>.size,
                    value: pointer
                ),
            ]
            return CTParagraphStyleCreate(settings, settings.count)
        }
    }
}
