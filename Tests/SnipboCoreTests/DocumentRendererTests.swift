import CoreGraphics
import Testing
@testable import SnipboCore

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

    @Test func testTextRenderingProducesPixels() throws {
        var document = EditDocument(image: try makeWhiteImage(width: 120, height: 60))
        document.annotations = [
            Annotation(
                kind: .text,
                geometry: .text(origin: CGPoint(x: 10, y: 10), width: 100, value: "Hello"),
                style: AnnotationStyle(color: .black, fontSize: 28),
                zIndex: 1
            ),
        ]
        let rendered = try #require(DocumentRenderer.render(document))
        #expect(rendered.width == 120)
        #expect(rendered.height == 60)
        #expect(nonWhitePixelCount(rendered) > 0)
    }

    @Test func testPixelateRenderingProducesImage() throws {
        var document = EditDocument(image: try makeWhiteImage(width: 80, height: 80))
        document.annotations = [
            Annotation(
                kind: .pixelate,
                geometry: .rect(CGRect(x: 10, y: 10, width: 40, height: 40)),
                style: AnnotationStyle(pixelBlockSize: 8),
                zIndex: 1
            ),
        ]
        let rendered = try #require(DocumentRenderer.render(document))
        #expect(rendered.width == 80)
        #expect(rendered.height == 80)
    }

    @Test func testPixelateRenderingBlocksNonUniformImage() throws {
        var document = EditDocument(image: try makeCheckerboardImage(width: 80, height: 80, cellSize: 4))
        document.annotations = [
            Annotation(
                kind: .pixelate,
                geometry: .rect(CGRect(x: 10, y: 10, width: 40, height: 40)),
                style: AnnotationStyle(pixelBlockSize: 8),
                zIndex: 1
            ),
        ]
        let rendered = try #require(DocumentRenderer.render(document))
        #expect(rendered.width == 80)
        #expect(rendered.height == 80)
        #expect(nonWhitePixelCount(rendered) > 0)
        // The 40x40 pixelate rect with block size 8 downsamples to 5x5, so the
        // first 8x8 output block (at the rect's top-left) is a single flattened
        // color. Without pixelation the checkerboard stays non-uniform there.
        #expect(try regionIsUniform(rendered, CGRect(x: 10, y: 10, width: 8, height: 8)))
    }

    @Test func testPixelateOutOfBoundsRectMatchesClippedRect() throws {
        // A 40x40 source clipped at the right edge: a rect extending to x=80
        // must render exactly like its in-bounds equivalent (x=20, width=20).
        // Sampling is clipped to the image bounds, so the destination must be
        // the clipped rect too; drawing into the unclipped rect would stretch
        // the in-bounds content horizontally and misalign blocks.
        let image = try makeCheckerboardImage(width: 40, height: 40, cellSize: 4)

        var extended = EditDocument(image: image)
        extended.annotations = [
            Annotation(
                kind: .pixelate,
                geometry: .rect(CGRect(x: 20, y: 0, width: 60, height: 20)),
                style: AnnotationStyle(pixelBlockSize: 4),
                zIndex: 1
            ),
        ]

        var clipped = EditDocument(image: image)
        clipped.annotations = [
            Annotation(
                kind: .pixelate,
                geometry: .rect(CGRect(x: 20, y: 0, width: 20, height: 20)),
                style: AnnotationStyle(pixelBlockSize: 4),
                zIndex: 1
            ),
        ]

        let renderedExtended = try #require(DocumentRenderer.render(extended))
        let renderedClipped = try #require(DocumentRenderer.render(clipped))

        #expect(renderedExtended.width == renderedClipped.width)
        #expect(renderedExtended.height == renderedClipped.height)
        #expect(try differingPixelCount(renderedExtended, renderedClipped) == 0)
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

private func makeCheckerboardImage(width: Int, height: Int, cellSize: Int) throws -> CGImage {
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
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    for row in stride(from: 0, to: height, by: cellSize) {
        for column in stride(from: 0, to: width, by: cellSize) {
            if (row / cellSize + column / cellSize) % 2 == 0 {
                context.fill(CGRect(x: column, y: row, width: cellSize, height: cellSize))
            }
        }
    }
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

/// Returns `true` when every pixel inside `rect` has the same RGB(A) value.
/// `rect` is expressed with a top-left origin, matching document coordinates.
private func regionIsUniform(_ image: CGImage, _ rect: CGRect) throws -> Bool {
    let width = image.width
    let height = image.height
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let data = try #require(context.data)
    let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

    let minX = max(0, Int(rect.minX))
    let minY = max(0, Int(rect.minY))
    let maxX = min(width, Int(rect.maxX))
    let maxY = min(height, Int(rect.maxY))
    guard minX < maxX, minY < maxY else { return true }

    let reference = (minY * width + minX) * 4
    for y in minY..<maxY {
        for x in minX..<maxX {
            let index = (y * width + x) * 4
            for channel in 0..<4 where bytes[index + channel] != bytes[reference + channel] {
                return false
            }
        }
    }
    return true
}

/// Returns the number of pixels whose RGBA channels differ between two images,
/// or `-1` when their dimensions differ.
private func differingPixelCount(_ lhs: CGImage, _ rhs: CGImage) throws -> Int {
    guard lhs.width == rhs.width, lhs.height == rhs.height else { return -1 }
    let lhsBytes = try rgbaBytes(lhs)
    let rhsBytes = try rgbaBytes(rhs)
    var count = 0
    for index in stride(from: 0, to: lhsBytes.count, by: 4) {
        if lhsBytes[index] != rhsBytes[index]
            || lhsBytes[index + 1] != rhsBytes[index + 1]
            || lhsBytes[index + 2] != rhsBytes[index + 2]
            || lhsBytes[index + 3] != rhsBytes[index + 3] {
            count += 1
        }
    }
    return count
}

/// Renders `image` into a premultiplied RGBA bitmap and returns its raw bytes.
private func rgbaBytes(_ image: CGImage) throws -> [UInt8] {
    let width = image.width
    let height = image.height
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let data = try #require(context.data)
    let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
    return Array(UnsafeBufferPointer(start: bytes, count: width * height * 4))
}
