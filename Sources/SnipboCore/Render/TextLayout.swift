import CoreGraphics
import CoreText
import Foundation

/// Layout shared by the renderer, selection bounds, and hit testing so a
/// multi-line text annotation is measured exactly the way it is drawn.
public enum TextLayout {
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
        let attributed = attributedString(value, width: resolvedWidth, style: style)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRangeMake(0, 0),
            nil,
            CGSize(width: resolvedWidth, height: .greatestFiniteMagnitude),
            nil
        )
        return CGSize(
            width: resolvedWidth,
            height: max(lineHeight, ceil(suggested.height))
        )
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
