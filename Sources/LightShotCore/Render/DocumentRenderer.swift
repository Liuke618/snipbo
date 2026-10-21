import CoreGraphics
import Foundation

public enum DocumentRenderer {
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
            draw(annotation, in: context, canvasHeight: canvasHeight, crop: crop)
        }
        return context.makeImage()
    }

    private static func draw(
        _ annotation: Annotation,
        in context: CGContext,
        canvasHeight: CGFloat,
        crop: CGRect
    ) {
        guard annotation.kind != .pixelate else { return }
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
            return
        }
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
