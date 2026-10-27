import CoreGraphics
import CoreImage
import CoreText
import Foundation

public enum DocumentRenderer {
    /// Shared CIContext for blur rendering. CIContext creation is expensive
    /// and the instance is thread-safe.
    nonisolated(unsafe) private static let ciContext = CIContext(options: nil)

    public static func render(_ document: EditDocument, scale: CGFloat = 1) -> CGImage? {
        let imageBounds = CGRect(x: 0, y: 0, width: document.image.width, height: document.image.height)
        let crop = document.cropRect.intersection(imageBounds).integral
        guard crop.width >= 1, crop.height >= 1 else { return nil }

        let renderScale = max(0.01, scale)
        let width = max(1, Int((crop.width * renderScale).rounded()))
        let height = max(1, Int((crop.height * renderScale).rounded()))
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
        context.scaleBy(x: renderScale, y: renderScale)
        let imageOrigin = CGPoint(
            x: -crop.minX,
            y: crop.maxY - CGFloat(document.image.height)
        )
        context.draw(
            document.image,
            in: CGRect(origin: imageOrigin, size: CGSize(width: document.image.width, height: document.image.height))
        )

        // Annotation drawing works in image-pixel coordinates; the context
        // scale maps those to the output resolution.
        let canvasHeight = CGFloat(crop.height)
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
        case .measure:
            drawMeasure(annotation, in: context, canvasHeight: canvasHeight, crop: crop)
            return
        case .pixelateBrush:
            drawPixelateBrush(annotation, in: context, canvasHeight: canvasHeight, crop: crop, source: source)
            return
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
            context.setAlpha(annotation.style.opacity)
            if let fill = annotation.style.fillColor {
                context.setFillColor(color(fill))
                if annotation.kind == .ellipse {
                    context.fillEllipse(in: cgRect)
                } else {
                    context.fill(cgRect)
                }
            }
            context.setStrokeColor(color(annotation.style.color))
            context.setLineWidth(annotation.style.lineWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            applyDash(annotation.style, to: context)
            if annotation.kind == .ellipse {
                context.strokeEllipse(in: cgRect)
            } else {
                context.stroke(cgRect)
            }
        case .line(let start, let end):
            let startCG = convert(start, canvasHeight: canvasHeight, crop: crop)
            let endCG = convert(end, canvasHeight: canvasHeight, crop: crop)
            context.setAlpha(annotation.style.opacity)
            if annotation.kind == .arrow {
                if annotation.style.arrowStyle == .simple {
                    drawSimpleArrow(from: startCG, to: endCG, in: context, style: annotation.style)
                } else if annotation.style.lineStyle == .dashed {
                    drawDashedTaperedArrow(from: startCG, to: endCG, in: context, style: annotation.style)
                } else {
                    drawTaperedArrow(from: startCG, to: endCG, in: context, style: annotation.style)
                }
            } else {
                context.setStrokeColor(color(annotation.style.color))
                context.setLineWidth(annotation.style.lineWidth)
                context.setLineCap(.round)
                applyDash(annotation.style, to: context)
                context.move(to: startCG)
                context.addLine(to: endCG)
                context.strokePath()
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
        case .polygon(let points):
            guard let first = points.first else { return }
            context.setAlpha(annotation.style.opacity)
            context.setStrokeColor(color(annotation.style.color))
            context.setLineWidth(annotation.style.lineWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            // Fewer than three vertices is an in-progress polygon: show the
            // placed vertices, and the edge once there are two, so the tool
            // gives feedback while it is being drawn.
            guard points.count >= 3 else {
                let radius = max(2, annotation.style.lineWidth * 0.9)
                context.setFillColor(color(annotation.style.color))
                for point in points {
                    let center = convert(point, canvasHeight: canvasHeight, crop: crop)
                    context.fillEllipse(in: CGRect(
                        x: center.x - radius,
                        y: center.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    ))
                }
                if points.count == 2 {
                    context.move(to: convert(first, canvasHeight: canvasHeight, crop: crop))
                    context.addLine(to: convert(points[1], canvasHeight: canvasHeight, crop: crop))
                    context.strokePath()
                }
                return
            }
            let path = CGMutablePath()
            path.move(to: convert(first, canvasHeight: canvasHeight, crop: crop))
            for point in points.dropFirst() {
                path.addLine(to: convert(point, canvasHeight: canvasHeight, crop: crop))
            }
            path.closeSubpath()
            if let fill = annotation.style.fillColor {
                context.addPath(path)
                context.setFillColor(color(fill))
                context.fillPath()
            }
            context.addPath(path)
            applyDash(annotation.style, to: context)
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
        guard case .text(let origin, let width, let value) = annotation.geometry,
              !value.isEmpty else { return }
        let style = annotation.style
        let layoutSize = TextLayout.size(value: value, width: width, style: style)
        let topLeft = convert(origin, canvasHeight: canvasHeight, crop: crop)
        context.saveGState()
        context.setAlpha(style.opacity)
        // Move the origin to the text box's top-left. CoreText lays the frame
        // out downward from y = 0, which matches the annotation's top-left
        // origin in the unflipped render context.
        context.translateBy(x: topLeft.x, y: topLeft.y)

        if let background = style.textBackground {
            let pad: CGFloat = 3
            let rect = CGRect(
                x: -pad,
                y: -layoutSize.height - pad,
                width: layoutSize.width + pad * 2,
                height: layoutSize.height + pad * 2
            )
            context.setFillColor(color(background))
            context.addPath(CGPath(
                roundedRect: rect,
                cornerWidth: 4,
                cornerHeight: 4,
                transform: nil
            ))
            context.fillPath()
        }

        let attributed = TextLayout.attributedString(value, width: width, style: style)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(
            rect: CGRect(
                x: 0,
                y: -layoutSize.height,
                width: layoutSize.width,
                height: layoutSize.height
            ),
            transform: nil
        )
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    /// Pixelates inside a round brush stroke, so users can scrub over a face
    /// or serial number instead of boxing it.
    private static func drawPixelateBrush(
        _ annotation: Annotation,
        in context: CGContext,
        canvasHeight: CGFloat,
        crop: CGRect,
        source: CGImage
    ) {
        guard case .path(let points) = annotation.geometry, !points.isEmpty else {
            return
        }
        let style = annotation.style
        let brushRadius = max(4, style.lineWidth * 3)
        context.saveGState()
        if points.count == 1, let first = points.first {
            let center = convert(first, canvasHeight: canvasHeight, crop: crop)
            context.addEllipse(in: CGRect(
                x: center.x - brushRadius,
                y: center.y - brushRadius,
                width: brushRadius * 2,
                height: brushRadius * 2
            ))
        } else {
            let path = CGMutablePath()
            path.move(to: convert(points[0], canvasHeight: canvasHeight, crop: crop))
            for point in points.dropFirst() {
                path.addLine(to: convert(point, canvasHeight: canvasHeight, crop: crop))
            }
            let stroked = path.copy(
                strokingWithWidth: brushRadius * 2,
                lineCap: .round,
                lineJoin: .round,
                miterLimit: 10
            )
            context.addPath(stroked)
        }
        context.clip()

        let pixelRect = crop.integral
        guard pixelRect.width >= 1, pixelRect.height >= 1,
              let sourceCrop = source.cropping(to: pixelRect) else {
            context.restoreGState()
            return
        }
        // Keep a few blocks across the brush so the stroke still reads as
        // pixelation instead of a flat eraser band.
        let blockSize = max(2, min(style.pixelBlockSize, max(4, brushRadius * 0.6)))
        let smallWidth = max(1, Int((pixelRect.width / blockSize).rounded(.up)))
        let smallHeight = max(1, Int((pixelRect.height / blockSize).rounded(.up)))
        guard let smallContext = CGContext(
            data: nil,
            width: smallWidth,
            height: smallHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            context.restoreGState()
            return
        }
        // Average while downscaling so a block carries the content's color,
        // then upscale without smoothing for the mosaic look.
        smallContext.interpolationQuality = .high
        smallContext.draw(
            sourceCrop,
            in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight)
        )
        guard let smallImage = smallContext.makeImage() else {
            context.restoreGState()
            return
        }
        context.interpolationQuality = .none
        context.draw(
            smallImage,
            in: convert(crop, canvasHeight: canvasHeight, crop: crop)
        )
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

    private static func applyDash(
        _ style: AnnotationStyle,
        to context: CGContext
    ) {
        if style.lineStyle == .dashed {
            let width = max(1, style.lineWidth)
            context.setLineDash(
                phase: 0,
                lengths: [max(4, width * 2.2), max(3, width * 1.6)]
            )
        } else {
            context.setLineDash(phase: 0, lengths: [])
        }
    }

    /// Classic line arrow with a two-stroke head, for users who prefer it to
    /// the solid tapered shape.
    private static func drawSimpleArrow(
        from start: CGPoint,
        to end: CGPoint,
        in context: CGContext,
        style: AnnotationStyle
    ) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = hypot(dx, dy)
        guard distance > 1 else { return }
        context.setStrokeColor(color(style.color))
        context.setLineWidth(max(2, style.lineWidth))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        applyDash(style, to: context)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()

        context.setLineDash(phase: 0, lengths: [])
        let angle = atan2(dy, dx)
        let headLength = max(10, style.lineWidth * 3.5)
        let spread = CGFloat.pi / 7
        let head1 = CGPoint(
            x: end.x - headLength * cos(angle - spread),
            y: end.y - headLength * sin(angle - spread)
        )
        let head2 = CGPoint(
            x: end.x - headLength * cos(angle + spread),
            y: end.y - headLength * sin(angle + spread)
        )
        context.move(to: head1)
        context.addLine(to: end)
        context.addLine(to: head2)
        context.strokePath()
    }

    /// Distance ruler: a line with end ticks and a pixel-distance badge.
    private static func drawMeasure(
        _ annotation: Annotation,
        in context: CGContext,
        canvasHeight: CGFloat,
        crop: CGRect
    ) {
        guard case .line(let start, let end) = annotation.geometry else { return }
        let a = convert(start, canvasHeight: canvasHeight, crop: crop)
        let b = convert(end, canvasHeight: canvasHeight, crop: crop)
        let dx = b.x - a.x
        let dy = b.y - a.y
        let distance = hypot(dx, dy)
        guard distance > 1 else { return }
        let style = annotation.style
        let nx = -dy / distance
        let ny = dx / distance

        context.saveGState()
        context.setAlpha(style.opacity)
        context.setStrokeColor(color(style.color))
        context.setLineWidth(max(1, style.lineWidth))
        context.setLineCap(.round)
        applyDash(style, to: context)
        context.move(to: a)
        context.addLine(to: b)
        context.strokePath()

        context.setLineDash(phase: 0, lengths: [])
        let tick = max(6, style.lineWidth * 2.5)
        context.move(to: CGPoint(x: a.x - nx * tick, y: a.y - ny * tick))
        context.addLine(to: CGPoint(x: a.x + nx * tick, y: a.y + ny * tick))
        context.move(to: CGPoint(x: b.x - nx * tick, y: b.y - ny * tick))
        context.addLine(to: CGPoint(x: b.x + nx * tick, y: b.y + ny * tick))
        context.strokePath()

        let fontSize = max(11, style.fontSize * 0.7)
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ]
        let text = "\(Int(distance.rounded())) px"
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let badgeHeight = ascent + descent + 4
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let offset: CGFloat = 12
        let badgeY = mid.y + offset + badgeHeight <= canvasHeight
            ? mid.y + offset
            : mid.y - offset - badgeHeight
        let badge = CGRect(
            x: mid.x - textWidth / 2 - 4,
            y: badgeY,
            width: textWidth + 8,
            height: badgeHeight
        )
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.7))
        context.addPath(CGPath(
            roundedRect: badge,
            cornerWidth: 3,
            cornerHeight: 3,
            transform: nil
        ))
        context.fillPath()
        context.textPosition = CGPoint(x: badge.minX + 4, y: badge.minY + 2 + descent)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// Shottr-style solid tapered arrow: rounded tail, a shaft that narrows
    /// toward the head, and a solid triangular head, all one filled shape. The
    /// old stroked shaft + separate head triangle made a wide stroke poke out
    /// of the head like a misaligned blob.
    /// A tapered arrow with a dashed shaft. The head stays solid so the
    /// direction still reads; only the body breaks into dashes.
    private static func drawDashedTaperedArrow(
        from start: CGPoint,
        to end: CGPoint,
        in context: CGContext,
        style: AnnotationStyle
    ) {
        let dx = end.x - start.x, dy = end.y - start.y
        let distance = hypot(dx, dy)
        guard distance > 1 else { return }
        let ux = dx / distance, uy = dy / distance
        let nx = -uy, ny = ux
        let width = max(2, style.lineWidth)
        let headLength = min(max(12, width * 3.4), distance * 0.55)
        let headHalf = headLength * 0.52
        let base = CGPoint(x: end.x - ux * headLength, y: end.y - uy * headLength)

        context.setStrokeColor(color(style.color))
        context.setLineWidth(width)
        context.setLineCap(.round)
        applyDash(style, to: context)
        context.move(to: start)
        context.addLine(to: base)
        context.strokePath()

        context.setLineDash(phase: 0, lengths: [])
        context.setFillColor(color(style.color))
        let head = CGMutablePath()
        head.move(to: CGPoint(x: base.x + nx * headHalf, y: base.y + ny * headHalf))
        head.addLine(to: end)
        head.addLine(to: CGPoint(x: base.x - nx * headHalf, y: base.y - ny * headHalf))
        head.closeSubpath()
        context.addPath(head)
        context.fillPath()
        context.fillEllipse(in: CGRect(
            x: start.x - width / 2,
            y: start.y - width / 2,
            width: width,
            height: width
        ))
    }

    private static func drawTaperedArrow(
        from start: CGPoint,
        to end: CGPoint,
        in context: CGContext,
        style: AnnotationStyle
    ) {
        let dx = end.x - start.x, dy = end.y - start.y
        let distance = hypot(dx, dy)
        guard distance > 1 else { return }
        let ux = dx / distance, uy = dy / distance
        let nx = -uy, ny = ux

        let width = max(2, style.lineWidth)
        // A short arrow shrinks its head so the tip stays at the end point.
        let headLength = min(max(12, width * 3.4), distance * 0.55)
        let headHalf = headLength * 0.52
        let tailHalf = width / 2
        let neckHalf = tailHalf * 0.5
        let base = CGPoint(x: end.x - ux * headLength, y: end.y - uy * headLength)

        let points = [
            CGPoint(x: start.x + nx * tailHalf, y: start.y + ny * tailHalf),
            CGPoint(x: base.x + nx * neckHalf, y: base.y + ny * neckHalf),
            CGPoint(x: base.x + nx * headHalf, y: base.y + ny * headHalf),
            end,
            CGPoint(x: base.x - nx * headHalf, y: base.y - ny * headHalf),
            CGPoint(x: base.x - nx * neckHalf, y: base.y - ny * neckHalf),
            CGPoint(x: start.x - nx * tailHalf, y: start.y - ny * tailHalf),
        ]
        context.setFillColor(color(style.color))
        context.move(to: points[0])
        for point in points.dropFirst() {
            context.addLine(to: point)
        }
        context.closePath()
        context.fillPath()
        // Rounded tail cap.
        context.fillEllipse(in: CGRect(
            x: start.x - tailHalf,
            y: start.y - tailHalf,
            width: width,
            height: width
        ))
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
