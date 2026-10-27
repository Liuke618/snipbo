import CoreGraphics
import Foundation
import Testing
@testable import SnipboCore

/// Pixel-level verification for the four Shottr-parity editor tools:
/// blur, spotlight, counter, and magnifier.
@Suite("EditorToolsRenderTests")
struct EditorToolsRenderTests {
    @Test func testBlurSmoothsHardEdge() throws {
        let base = try makeTwoToneBase()
        var document = EditDocument(image: base)
        document.annotations = [Annotation(
            kind: .blur,
            geometry: .rect(CGRect(x: 12, y: 10, width: 16, height: 20)),
            style: AnnotationStyle(pixelBlockSize: 8),
            zIndex: 1
        )]
        let rendered = try #require(DocumentRenderer.render(document))
        // The sharp edge at x=20 sits inside the blur rect; blurring turns the
        // pure red/blue boundary into a blend.
        let edge = try #require(rendered.pixel(atX: 20, y: 20))
        #expect(abs(Int(edge.red) - Int(edge.blue)) < 60)
        // Far outside the blur rect the base stays untouched: pure red.
        let outside = try #require(rendered.pixel(atX: 5, y: 20))
        #expect(outside.red > 200 && outside.blue < 40)
    }

    @Test func testSpotlightDimsOutsideTheEllipseOnly() throws {
        let base = try makeSolidBase(gray: 200)
        var document = EditDocument(image: base)
        var style = AnnotationStyle()
        style.opacity = 0.5
        document.annotations = [Annotation(
            kind: .spotlight,
            geometry: .rect(CGRect(x: 10, y: 10, width: 20, height: 20)),
            style: style,
            zIndex: 1
        )]
        let rendered = try #require(DocumentRenderer.render(document))
        // Center of the ellipse keeps the base brightness; the corner is
        // dimmed by the 50% black overlay.
        let inside = try #require(rendered.pixel(atX: 20, y: 20))
        #expect(abs(Int(inside.red) - 200) <= 8)
        let corner = try #require(rendered.pixel(atX: 2, y: 2))
        #expect(abs(Int(corner.red) - 100) <= 10)
    }

    @Test func testCounterDrawsBadgeWithValue() throws {
        let base = try makeSolidBase(gray: 255)
        var document = EditDocument(image: base)
        document.annotations = [Annotation(
            kind: .counter,
            geometry: .badge(center: CGPoint(x: 20, y: 20), value: 3),
            style: AnnotationStyle(),
            zIndex: 1
        )]
        let rendered = try #require(DocumentRenderer.render(document))
        // Off-center inside the circle (clear of the digit glyph) is badge red.
        let badge = try #require(rendered.pixel(atX: 28, y: 20))
        #expect(badge.red > 180 && badge.blue < 80)
        // Outside the 24px circle the base stays white.
        let outside = try #require(rendered.pixel(atX: 5, y: 20))
        #expect(outside.red > 240 && outside.green > 240)
    }

    @Test func testMagnifierZoomsSourceRegion() throws {
        let base = try makeTwoToneBase()
        var document = EditDocument(image: base)
        document.annotations = [Annotation(
            kind: .magnifier,
            geometry: .lens(
                center: CGPoint(x: 30, y: 20),
                source: CGPoint(x: 10, y: 20),
                radius: 8
            ),
            style: AnnotationStyle(),
            zIndex: 1
        )]
        let rendered = try #require(DocumentRenderer.render(document))
        // The lens magnifies the red source area, so its center is red even
        // though the lens sits over the blue half.
        let lens = try #require(rendered.pixel(atX: 30, y: 20))
        #expect(lens.red > 180 && lens.blue < 60)
        // Outside the lens and its ring (center + radius + half stroke width)
        // the canvas shows the untouched blue base.
        let outside = try #require(rendered.pixel(atX: 30, y: 39))
        #expect(outside.blue > 180 && outside.red < 60)
    }

    @Test func testShapeFillAndDashedLine() throws {
        let base = try makeSolidBase(gray: 255)
        var filled = EditDocument(image: base)
        filled.annotations = [Annotation(
            kind: .rectangle,
            geometry: .rect(CGRect(x: 10, y: 10, width: 20, height: 20)),
            style: AnnotationStyle(
                color: .red,
                lineWidth: 2,
                fillColor: RGBA(red: 0, green: 0, blue: 1, alpha: 1)
            ),
            zIndex: 1
        )]
        let filledImage = try #require(DocumentRenderer.render(filled))
        let center = try #require(filledImage.pixel(atX: 20, y: 20))
        #expect(center.blue > 180 && center.red < 80)

        var solid = EditDocument(image: base)
        solid.annotations = [Annotation(
            kind: .line,
            geometry: .line(start: CGPoint(x: 5, y: 20), end: CGPoint(x: 35, y: 20)),
            style: AnnotationStyle(color: .red, lineWidth: 2),
            zIndex: 1
        )]
        var dashed = solid
        dashed.annotations[0].style.lineStyle = .dashed
        let solidImage = try #require(DocumentRenderer.render(solid))
        let dashedImage = try #require(DocumentRenderer.render(dashed))
        let solidCount = solidImage.redPixelCount()
        let dashedCount = dashedImage.redPixelCount()
        #expect(solidCount > 20)
        #expect(dashedCount > 0)
        #expect(dashedCount < solidCount)
    }

    @Test func testMeasureAndSimpleArrowRender() throws {
        let base = try makeSolidBase(gray: 255)
        var document = EditDocument(image: base)
        document.annotations = [
            Annotation(
                kind: .measure,
                geometry: .line(start: CGPoint(x: 5, y: 30), end: CGPoint(x: 35, y: 30)),
                style: AnnotationStyle(color: .red, lineWidth: 2, fontSize: 12),
                zIndex: 1
            ),
            Annotation(
                kind: .arrow,
                geometry: .line(start: CGPoint(x: 5, y: 10), end: CGPoint(x: 35, y: 10)),
                style: AnnotationStyle(
                    color: .red,
                    lineWidth: 2,
                    arrowStyle: .simple
                ),
                zIndex: 2
            ),
        ]
        let rendered = try #require(DocumentRenderer.render(document))
        let measureLine = try #require(rendered.pixel(atX: 20, y: 30))
        #expect(measureLine.red > 180)
        let arrowLine = try #require(rendered.pixel(atX: 20, y: 10))
        #expect(arrowLine.red > 180)
    }

    @Test func testDashedTaperedArrowBreaksTheShaft() throws {
        // A dark base separates the painted shaft from the background; a white
        // one leaves both at red 255.
        let base = try makeSolidBase(gray: 30)
        func painted(_ dashed: Bool) throws -> Int {
            var document = EditDocument(image: base)
            document.annotations = [Annotation(
                kind: .arrow,
                geometry: .line(start: CGPoint(x: 4, y: 20), end: CGPoint(x: 36, y: 20)),
                style: AnnotationStyle(
                    color: .red,
                    lineWidth: 4,
                    lineStyle: dashed ? .dashed : .solid
                ),
                zIndex: 1
            )]
            let rendered = try #require(DocumentRenderer.render(document))
            var count = 0
            for x in 6..<24 {
                if let pixel = rendered.pixel(atX: x, y: 20), pixel.red > 180 {
                    count += 1
                }
            }
            return count
        }
        let solid = try painted(false)
        let dashed = try painted(true)
        #expect(solid == 18)
        #expect(dashed < solid)
    }

    @Test func testPolygonFillsAndHitsInside() throws {
        let base = try makeSolidBase(gray: 255)
        var document = EditDocument(image: base)
        let polygon = Annotation(
            kind: .polygon,
            geometry: .polygon(points: [
                CGPoint(x: 10, y: 10),
                CGPoint(x: 30, y: 10),
                CGPoint(x: 20, y: 30),
            ]),
            style: AnnotationStyle(
                color: .red,
                lineWidth: 2,
                fillColor: RGBA(red: 0, green: 0, blue: 1, alpha: 1)
            ),
            zIndex: 1
        )
        document.annotations = [polygon]
        let rendered = try #require(DocumentRenderer.render(document))
        let inside = try #require(rendered.pixel(atX: 20, y: 20))
        #expect(inside.blue > 180 && inside.red < 80)
        let outside = try #require(rendered.pixel(atX: 2, y: 2))
        #expect(outside.red > 240 && outside.blue > 240)

        #expect(AnnotationHitTester.topmost(
            in: [polygon],
            at: CGPoint(x: 20, y: 20),
            tolerance: 1
        ) != nil)
        #expect(AnnotationHitTester.topmost(
            in: [polygon],
            at: CGPoint(x: 2, y: 2),
            tolerance: 1
        ) == nil)
    }

    @Test func testPolygonPreviewShowsVerticesAndEdgeBeforeClosing() throws {
        let base = try makeSolidBase(gray: 255)
        var document = EditDocument(image: base)
        document.annotations = [Annotation(
            kind: .polygon,
            geometry: .polygon(points: [
                CGPoint(x: 10, y: 10),
                CGPoint(x: 30, y: 10),
            ]),
            style: AnnotationStyle(color: .red, lineWidth: 2),
            zIndex: 1
        )]
        let rendered = try #require(DocumentRenderer.render(document))

        let vertex = try #require(rendered.pixel(atX: 10, y: 10))
        #expect(vertex.red > 180 && vertex.blue < 120)
        let edge = try #require(rendered.pixel(atX: 20, y: 10))
        #expect(edge.red > 180 && edge.blue < 120)
        let empty = try #require(rendered.pixel(atX: 20, y: 25))
        #expect(empty.red > 240 && empty.blue > 240)
    }

    @Test func testPixelateBrushRendersInsideStrokeOnly() throws {
        let base = try makeTwoToneBase()
        var document = EditDocument(image: base)
        document.annotations = [Annotation(
            kind: .pixelateBrush,
            geometry: .path(points: [
                CGPoint(x: 8, y: 20),
                CGPoint(x: 32, y: 20),
            ]),
            style: AnnotationStyle(lineWidth: 3, pixelBlockSize: 8),
            zIndex: 1
        )]
        let rendered = try #require(DocumentRenderer.render(document))
        // Outside the brush the sharp red/blue base survives.
        let top = try #require(rendered.pixel(atX: 5, y: 2))
        #expect(top.red > 200 && top.blue < 60)
        // Inside the stroke the content is still present (pixelation samples
        // the base image rather than leaving a hole).
        let inside = try #require(rendered.pixel(atX: 25, y: 20))
        #expect(inside.blue > 150)
    }

    @Test func testNewAnnotationKindsRoundTrip() throws {
        let annotations = [
            Annotation(kind: .counter, geometry: .badge(center: CGPoint(x: 5, y: 6), value: 2), style: AnnotationStyle(), zIndex: 1),
            Annotation(kind: .magnifier, geometry: .lens(center: CGPoint(x: 1, y: 2), source: CGPoint(x: 3, y: 4), radius: 8), style: AnnotationStyle(), zIndex: 2),
            Annotation(kind: .blur, geometry: .rect(CGRect(x: 0, y: 0, width: 8, height: 8)), style: AnnotationStyle(pixelBlockSize: 10), zIndex: 3),
            Annotation(kind: .spotlight, geometry: .rect(CGRect(x: 2, y: 2, width: 9, height: 9)), style: AnnotationStyle(opacity: 0.55), zIndex: 4),
        ]
        let data = try JSONEncoder().encode(annotations)
        let decoded = try JSONDecoder().decode([Annotation].self, from: data)
        #expect(decoded == annotations)
    }
}

// MARK: - Fixtures

private func makeTwoToneBase() throws -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = try #require(CGContext(
        data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 0, 0, 1])!)
    context.fill(CGRect(x: 0, y: 0, width: 20, height: 40))
    context.setFillColor(CGColor(colorSpace: colorSpace, components: [0, 0, 1, 1])!)
    context.fill(CGRect(x: 20, y: 0, width: 20, height: 40))
    return try #require(context.makeImage())
}

private func makeSolidBase(gray: UInt8) throws -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = try #require(CGContext(
        data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let value = CGFloat(gray) / 255
    context.setFillColor(CGColor(colorSpace: colorSpace, components: [value, value, value, 1])!)
    context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
    return try #require(context.makeImage())
}

private struct RGBAPixel {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

private extension CGImage {
    func redPixelCount() -> Int {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { return 0 }
        context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var count = 0
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            if bytes[index] > 180 && bytes[index + 1] < 80 && bytes[index + 2] < 80 {
                count += 1
            }
        }
        return count
    }

    /// Non-throwing on purpose: #require only unwraps the optional.
    func pixel(atX x: Int, y: Int) -> RGBAPixel? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { return nil }
        context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let offset = (y * width + x) * 4
        return RGBAPixel(red: bytes[offset], green: bytes[offset + 1], blue: bytes[offset + 2])
    }
}
