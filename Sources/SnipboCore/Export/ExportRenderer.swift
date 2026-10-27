import CoreGraphics
import CoreText
import Foundation

public struct WatermarkOptions: Sendable {
    public var text: String
    public var position: WatermarkPosition
    public var opacity: Double

    public init(text: String, position: WatermarkPosition, opacity: Double) {
        self.text = text
        self.position = position
        self.opacity = opacity
    }
}

public struct BeautifyOptions: Sendable {
    public var padding: Int
    public var cornerRadius: Int
    /// nil keeps the padding transparent.
    public var background: RGBA?
    public var shadow: Bool

    public init(
        padding: Int,
        cornerRadius: Int,
        background: RGBA?,
        shadow: Bool
    ) {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.background = background
        self.shadow = shadow
    }
}

public struct ExportAppearance: Sendable {
    public var watermark: WatermarkOptions?
    public var beautify: BeautifyOptions?

    public init(watermark: WatermarkOptions? = nil, beautify: BeautifyOptions? = nil) {
        self.watermark = watermark
        self.beautify = beautify
    }

    public var hasWork: Bool { watermark != nil || beautify != nil }
}

/// Applies the optional share-facing presentation (padding, background,
/// rounded corners, shadow, watermark) to an already rendered screenshot.
/// Pins and internal history keep the plain image.
public enum ExportRenderer {
    public static func apply(
        _ image: CGImage,
        options: ExportAppearance
    ) -> CGImage? {
        guard options.hasWork else { return image }
        var current = image
        if let beautify = options.beautify {
            guard let composed = beautified(current, options: beautify) else {
                return nil
            }
            current = composed
        }
        if let watermark = options.watermark, !watermark.text.isEmpty {
            guard let stamped = watermarked(current, options: watermark) else {
                return nil
            }
            current = stamped
        }
        return current
    }

    private static func beautified(
        _ image: CGImage,
        options: BeautifyOptions
    ) -> CGImage? {
        let padding = max(0, options.padding)
        let radius = min(
            CGFloat(max(0, options.cornerRadius)),
            min(CGFloat(image.width), CGFloat(image.height)) / 2
        )
        guard padding > 0 || radius > 0 || options.background != nil else {
            return image
        }
        let width = image.width + padding * 2
        let height = image.height + padding * 2
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        if let background = options.background {
            context.setFillColor(CGColor(
                red: background.red,
                green: background.green,
                blue: background.blue,
                alpha: background.alpha
            ))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }

        let imageRect = CGRect(
            x: padding,
            y: padding,
            width: image.width,
            height: image.height
        )
        let path = CGPath(
            roundedRect: imageRect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        if options.shadow {
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -6),
                blur: 20,
                color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28)
            )
            context.addPath(path)
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fillPath()
            context.restoreGState()
        }
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.interpolationQuality = .high
        context.draw(image, in: imageRect)
        context.restoreGState()
        return context.makeImage()
    }

    private static func watermarked(
        _ image: CGImage,
        options: WatermarkOptions
    ) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )

        let fontSize = max(
            14,
            min(72, min(CGFloat(image.width), CGFloat(image.height)) / 40)
        )
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: options.text, attributes: attributes)
        )
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let textWidth = CGFloat(
            CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        )
        let padding: CGFloat = 16
        let x: CGFloat
        let y: CGFloat
        switch options.position {
        case .topLeft:
            x = padding
            y = CGFloat(image.height) - padding - ascent
        case .topRight:
            x = CGFloat(image.width) - padding - textWidth
            y = CGFloat(image.height) - padding - ascent
        case .bottomLeft:
            x = padding
            y = padding
        case .bottomRight:
            x = CGFloat(image.width) - padding - textWidth
            y = padding
        case .center:
            x = (CGFloat(image.width) - textWidth) / 2
            y = (CGFloat(image.height) - ascent - descent) / 2
        }

        context.saveGState()
        context.setAlpha(max(0.05, min(1, options.opacity)))
        context.setShadow(
            offset: CGSize(width: 0, height: -1),
            blur: 3,
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.75)
        )
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
        context.restoreGState()
        return context.makeImage()
    }
}

extension BeautifyBackground {
    public var rgba: RGBA? {
        switch self {
        case .light: return RGBA(red: 0.96, green: 0.96, blue: 0.97)
        case .dark: return RGBA(red: 0.11, green: 0.11, blue: 0.12)
        case .blue: return RGBA(red: 0.13, green: 0.37, blue: 0.72)
        case .transparent: return nil
        }
    }
}

extension AppSettings {
    public var exportAppearance: ExportAppearance {
        let watermark = watermarkEnabled
            && !watermarkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? WatermarkOptions(
                text: watermarkText,
                position: watermarkPosition,
                opacity: watermarkOpacity
            )
            : nil
        let beautify = beautifyEnabled
            ? BeautifyOptions(
                padding: beautifyPadding,
                cornerRadius: beautifyCornerRadius,
                background: beautifyBackground.rgba,
                shadow: beautifyShadow
            )
            : nil
        return ExportAppearance(watermark: watermark, beautify: beautify)
    }
}
