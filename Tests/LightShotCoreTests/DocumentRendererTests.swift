import CoreGraphics
import Testing
@testable import LightShotCore

@Suite("DocumentRendererTests")
struct DocumentRendererTests {
    @Test func testRenderingRectangleChangesPixels() throws {
        var document = EditDocument(image: try makeWhiteImage(width: 40, height: 40))
        document.annotations = [
            Annotation(
                kind: .rectangle,
                geometry: .rect(CGRect(x: 10, y: 10, width: 20, height: 20)),
                style: AnnotationStyle(color: .red, lineWidth: 4),
                zIndex: 1
            ),
        ]
        let rendered = try #require(DocumentRenderer.render(document))
        #expect(nonWhitePixelCount(rendered) > 0)
    }

    @Test func testCropChangesOutputSize() throws {
        var document = EditDocument(image: try makeWhiteImage(width: 100, height: 80))
        document.cropRect = CGRect(x: 10, y: 10, width: 30, height: 20)
        let rendered = try #require(DocumentRenderer.render(document))
        #expect(rendered.width == 30)
        #expect(rendered.height == 20)
    }

    @Test func testArrowRenders() throws {
        var document = EditDocument(image: try makeWhiteImage(width: 60, height: 60))
        document.annotations = [
            Annotation(
                kind: .arrow,
                geometry: .line(start: CGPoint(x: 5, y: 5), end: CGPoint(x: 50, y: 50)),
                style: AnnotationStyle(),
                zIndex: 1
            ),
        ]
        let rendered = try #require(DocumentRenderer.render(document))
        #expect(nonWhitePixelCount(rendered) > 0)
    }

    @Test func testFreehandRenders() throws {
        var document = EditDocument(image: try makeWhiteImage(width: 60, height: 60))
        document.annotations = [
            Annotation(
                kind: .freehand,
                geometry: .path(points: [CGPoint(x: 5, y: 50), CGPoint(x: 30, y: 20), CGPoint(x: 55, y: 55)]),
                style: AnnotationStyle(),
                zIndex: 1
            ),
        ]
        let rendered = try #require(DocumentRenderer.render(document))
        #expect(nonWhitePixelCount(rendered) > 0)
    }

    @Test func testEllipseRenders() throws {
        var document = EditDocument(image: try makeWhiteImage(width: 60, height: 60))
        document.annotations = [
            Annotation(
                kind: .ellipse,
                geometry: .rect(CGRect(x: 10, y: 10, width: 40, height: 30)),
                style: AnnotationStyle(color: .red, lineWidth: 4),
                zIndex: 1
            ),
        ]
        let rendered = try #require(DocumentRenderer.render(document))
        #expect(nonWhitePixelCount(rendered) > 0)
    }

    @Test func testLineRenders() throws {
        var document = EditDocument(image: try makeWhiteImage(width: 60, height: 60))
        document.annotations = [
            Annotation(
                kind: .line,
                geometry: .line(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 50, y: 50)),
                style: AnnotationStyle(color: .red, lineWidth: 4),
                zIndex: 1
            ),
        ]
        let rendered = try #require(DocumentRenderer.render(document))
        #expect(nonWhitePixelCount(rendered) > 0)
    }

    @Test func testHighlightRenders() throws {
        var document = EditDocument(image: try makeWhiteImage(width: 60, height: 60))
        document.annotations = [
            Annotation(
                kind: .highlight,
                geometry: .line(start: CGPoint(x: 10, y: 30), end: CGPoint(x: 50, y: 30)),
                style: AnnotationStyle(
                    color: RGBA(red: 1, green: 1, blue: 0, alpha: 0.4),
                    lineWidth: 14
                ),
                zIndex: 1
            ),
        ]
        let rendered = try #require(DocumentRenderer.render(document))
        #expect(nonWhitePixelCount(rendered) > 0)
    }

    @Test func testPixelateIsSkipped() throws {
        var document = EditDocument(image: try makeWhiteImage(width: 60, height: 60))
        document.annotations = [
            Annotation(
                kind: .pixelate,
                geometry: .rect(CGRect(x: 10, y: 10, width: 40, height: 40)),
                style: AnnotationStyle(color: .red, lineWidth: 8),
                zIndex: 1
            ),
        ]
        let rendered = try #require(DocumentRenderer.render(document))
        #expect(nonWhitePixelCount(rendered) == 0)
    }
}

private func makeWhiteImage(width: Int, height: Int) throws -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}

private func nonWhitePixelCount(_ image: CGImage) -> Int {
    let width = image.width
    let height = image.height
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return 0 }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = context.data else { return 0 }
    let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
    var count = 0
    for index in stride(from: 0, to: width * height * 4, by: 4) {
        if bytes[index] < 250 || bytes[index + 1] < 250 || bytes[index + 2] < 250 {
            count += 1
        }
    }
    return count
}
