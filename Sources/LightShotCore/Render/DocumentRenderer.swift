import CoreGraphics
import CoreImage
import CoreText
import Foundation

public enum DocumentRenderer {
    /// Shared CIContext for blur rendering. CIContext creation is expensive
    /// and the instance is thread-safe.
    private static let ciContext = CIContext(options: nil)

    public static func render(_ document: EditDocument) -> CGImage? {
        let imageBounds = CGRect(x: 0, y: 0, width: document.image.width, height: document.image.height)
        let crop = document.cropRect.intersection(imageBounds).integral
        guard crop.width >= 1, crop.height >= 1 else { return nil }

        let width = Int(crop.width)
        let height = Int(crop.height)
        let colorSpace = document.image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
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
        let imageOrigin = CGPoint(
            x: -crop.minX,
            y: crop.maxY - CGFloat(document.image.height)
        )
        context.draw(
            document.image,
            in: CGRect(origin: imageOrigin, size: CGSize(width: document.image.width, height: document.image.height))
        )

        let canvasHeight = CGFloat(height)
        for annotation in document.annotations.sorted(by: { $0.zIndex < $1.zIndex }) {
            context.saveGState()
            draw(annotation, in: context, canvasHeight: canvasHeight, crop: crop, source: document.image)
            context.restoreGState()
        }
        return context.makeImage()
    }

    private static func draw(
        _ annotation: Annotation,
        in context: CGContext,
        canvasHeight: CGFloat,
        crop: CGRect,
        source: CGImage
    ) {
        switch annotation.kind {
        case .pixelate:
            drawPixelate(annotation, in: context, canvasHeight: canvasHeight, crop: crop, source: source)
            return
        case .blur:
            drawBlur(annotation, in: context, canvasHeight: canvasHeight, crop: crop, source: source)
            return
        case .spotlight:
            drawSpotlight(annotation, in: context, canvasHeight: canvasHeight, crop: crop)
            return
        case .counter:
            drawCounter(annotation, in: context, canvasHeight: canvasHeight, crop: crop)
            return
        case .magnifier:
            drawMagnifier(annotation, in: context, canvasHeight: canvasHeight, crop: crop, source: source)
            return
        default:
            break
        }

        switch annotation.geometry {
        case .rect(let rect):
            let cgRect = convert(rect, canvasHeight: canvasHeight, crop: crop)
            context.setStrokeColor(color(annotation.style.color))
            context.setLineWidth(annotation.style.lineWidth)
            context.setAlpha(annotation.style.opacity)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            if annotation.kind == .ellipse {
                context.strokeEllipse(in: cgRect)
            } else {
                context.stroke(cgRect)
            }
        case .line(let start, let end):
            let startCG = convert(start, canvasHeight: canvasHeight, crop: crop)
            let endCG = convert(end, canvasHeight: canvasHeight, crop: crop)
            context.setStrokeColor(color(annotation.style.color))
            context.setLineWidth(annotation.style.lineWidth)
            context.setAlpha(annotation.style.opacity)
            context.setLineCap(.round)
            context.move(to: startCG)
            context.addLine(to: endCG)
            context.strokePath()
            if annotation.kind == .arrow {
                drawArrowHead(from: startCG, to: endCG, in: context, style: annotation.style)
            }
        case .path(let points):
            guard let first = points.first else { return }
            context.setStrokeColor(color(annotation.style.color))
            context.setLineWidth(annotation.style.lineWidth)
            context.setAlpha(annotation.style.opacity)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: convert(first, canvasHeight: canvasHeight, crop: crop))
            for point in points.dropFirst() {
                context.addLine(to: convert(point, canvasHeight: canvasHeight, crop: crop))
            }
            context.strokePath()
        case .text:
            drawText(annotation, in: context, canvasHeight: canvasHeight, crop: crop)
        case .badge, .lens:
            // Handled by the kind switch above; nothing to draw generically.
            break
        }
    }

    private static func drawText(
        _ annotation: Annotation,
        in context: CGContext,
        canvasHeight: CGFloat,
        crop: CGRect
    ) {
        guard case .text(let origin, _, let value) = annotation.geometry, !value.isEmpty else { return }
        let font = CTFontCreateUIFontForLanguage(.system, annotation.style.fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, annotation.style.fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(annotation.style.color),
        ]
        let attributed = NSAttributedString(string: value, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, nil, nil)
        let topLeft = convert(origin, canvasHeight: canvasHeight, crop: crop)
        context.saveGState()
        context.setAlpha(annotation.style.opacity)
        context.textPosition = CGPoint(x: topLeft.x, y: topLeft.y - ascent)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func drawPixelate(
        _ annotation: Annotation,
        in context: CGContext,
        canvasHeight: CGFloat,
        crop: CGRect,
        source: CGImage
    ) {
        guard case .rect(let rect) = annotation.geometry else { return }
        let imageBounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let pixelRect = rect.intersection(imageBounds).integral
        guard pixelRect.width >= 1, pixelRect.height >= 1,
              let sourceCrop = source.cropping(to: pixelRect) else { return }

        let blockSize = max(1, annotation.style.pixelBlockSize)
        let smallWidth = max(1, Int(pixelRect.width / blockSize))
        let smallHeight = max(1, Int(pixelRect.height / blockSize))
        guard let smallContext = CGContext(
            data: nil,
            width: smallWidth,
            height: smallHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        smallContext.interpolationQuality = .none
        smallContext.draw(sourceCrop, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
        guard let smallImage = smallContext.makeImage() else { return }

        let cgRect = convert(pixelRect, canvasHeight: canvasHeight, crop: crop)
        context.saveGState()
        context.interpolationQuality = .none
        context.draw(smallImage, in: cgRect)
        context.restoreGState()
    }

    /// Gaussian blur of the region, taken from the base image so the blur
    /// never samples annotations drawn beneath it in an unexpected state.
    private static func drawBlur(
        _ annotation: Annotation,
        in context: CGContext,
        canvasHeight: CGFloat,
        crop: CGRect,
        source: CGImage
    ) {
        guard case .rect(let rect) = annotation.geometry else { return }
        let imageBounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let pixelRect = rect.intersection(imageBounds).integral
        guard pixelRect.width >= 1, pixelRect.height >= 1,
              let sourceCrop = source.cropping(to: pixelRect) else { return }

        let radius = Double(max(2, annotation.style.pixelBlockSize))
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return }
        filter.setValue(CIImage(cgImage: sourceCrop).clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage,
              let blurred = ciContext.createCGImage(
                output,
                from: CGRect(x: 0, y: 0, width: pixelRect.width, height: pixelRect.height)
              ) else { return }

        let cgRect = convert(pixelRect, canvasHeight: canvasHeight, crop: crop)
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(blurred, in: cgRect)
        context.restoreGState()
    }

    /// Dims the whole canvas except the ellipse inscribed in the rect.
    private static func drawSpotlight(
        _ annotation: Annotation,
        in context: CGContext,
        canvasHeight: CGFloat,
        crop: CGRect
    ) {
        guard case .rect(let rect) = annotation.geometry else { return }
        let cgRect = convert(rect, canvasHeight: canvasHeight, crop: crop)
        let canvas = CGRect(x: 0, y: 0, width: crop.width, height: canvasHeight)
        let path = CGMutablePath()
        path.addRect(canvas)
        path.addEllipse(in: cgRect)
        context.addPath(path)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: annotation.style.opacity))
        context.fillPath(using: .evenOdd)
    }

    /// Numbered step badge: filled circle with a white digit.
    private static func drawCounter(
        _ annotation: Annotation,
        in context: CGContext,
        canvasHeight: CGFloat,
        crop: CGRect
    ) {
        guard case .badge(let center, let value) = annotation.geometry else { return }
        let diameter = max(24, annotation.style.fontSize)
        let cgCenter = convert(center, canvasHeight: canvasHeight, crop: crop)
        let circle = CGRect(
            x: cgCenter.x - diameter / 2,
            y: cgCenter.y - diameter / 2,
            width: diameter,
            height: diameter
        )
        context.setFillColor(color(annotation.style.color))
        context.fillEllipse(in: circle)

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, diameter * 0.62, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\(value)", attributes: attributes))
        var ascent: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, nil, nil))
        context.textPosition = CGPoint(x: cgCenter.x - textWidth / 2, y: cgCenter.y - ascent / 2)
        CTLineDraw(line, context)
    }

    /// Circular callout magnifying the base image around `source`.
    private static func drawMagnifier(
        _ annotation: Annotation,
        in context: CGContext,
        canvasHeight: CGFloat,
        crop: CGRect,
        source: CGImage
    ) {
        guard case .lens(let center, let sourcePoint, let radius) = annotation.geometry else { return }
        let cgCenter = convert(center, canvasHeight: canvasHeight, crop: crop)
        let cgSource = convert(sourcePoint, canvasHeight: canvasHeight, crop: crop)
        let circle = CGRect(
            x: cgCenter.x - radius,
            y: cgCenter.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        guard circle.width >= 4 else { return }

        let zoom: CGFloat = 2
        context.saveGState()
        context.addEllipse(in: circle)
        context.clip()
        context.translateBy(x: cgCenter.x, y: cgCenter.y)
        context.scaleBy(x: zoom, y: zoom)
        context.translateBy(x: -cgSource.x, y: -cgSource.y)
        let imageOrigin = CGPoint(
            x: -crop.minX,
            y: crop.maxY - CGFloat(source.height)
        )
        context.draw(
            source,
            in: CGRect(origin: imageOrigin, size: CGSize(width: source.width, height: source.height))
        )
        context.restoreGState()

        context.setStrokeColor(color(annotation.style.color))
        context.setLineWidth(max(1, annotation.style.lineWidth))
        context.strokeEllipse(in: circle)
    }

    private static func drawArrowHead(
        from start: CGPoint,
        to end: CGPoint,
        in context: CGContext,
        style: AnnotationStyle
    ) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = max(8, style.lineWidth * 3)
        let spread = CGFloat.pi / 7
        let left = CGPoint(x: end.x - length * cos(angle - spread), y: end.y - length * sin(angle - spread))
        let right = CGPoint(x: end.x - length * cos(angle + spread), y: end.y - length * sin(angle + spread))
        context.setFillColor(color(style.color))
        context.move(to: end)
        context.addLine(to: left)
        context.addLine(to: right)
        context.closePath()
        context.fillPath()
    }

    private static func convert(_ point: CGPoint, canvasHeight: CGFloat, crop: CGRect) -> CGPoint {
        CGPoint(x: point.x - crop.minX, y: canvasHeight - (point.y - crop.minY))
    }

    private static func convert(_ rect: CGRect, canvasHeight: CGFloat, crop: CGRect) -> CGRect {
        CGRect(
            x: rect.minX - crop.minX,
            y: canvasHeight - (rect.maxY - crop.minY),
            width: rect.width,
            height: rect.height
        )
    }

    private static func color(_ rgba: RGBA) -> CGColor {
        CGColor(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
    }
}
