import CoreGraphics
import ImageIO
import Testing
@testable import LightShotCore

@Suite("ImageExporterTests")
struct ImageExporterTests {
    @Test func testPNGExportDecodesWithSameSize() throws {
        let image = try makeSolidImage(width: 12, height: 8)
        let data = try #require(ImageExporter.pngData(from: image))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 12)
        #expect(decoded.height == 8)
    }

    @Test func testJPEGExportProducesData() throws {
        let image = try makeSolidImage(width: 12, height: 8)
        let data = try #require(ImageExporter.jpegData(from: image, quality: 0.7))
        #expect(!data.isEmpty)
    }
}

private func makeSolidImage(width: Int, height: Int) throws -> CGImage {
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
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}
