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

    @Test func testDownscaleHalvesDimensionsAndKeepsColor() throws {
        let image = try makeSolidImage(width: 8, height: 4)
        let downscaled = ImageExporter.downscaled(image, by: 0.5)
        #expect(downscaled.width == 4)
        #expect(downscaled.height == 2)
        // A uniform color survives interpolation exactly.
        let red = try #require(downscaled.pixelRed(atX: 2, y: 1))
        #expect(abs(Int(red) - 51) <= 2)
    }

    @Test func testDownscaleRejectsOutOfRangeFactor() throws {
        let image = try makeSolidImage(width: 8, height: 4)
        #expect(ImageExporter.downscaled(image, by: 0).width == 8)
        #expect(ImageExporter.downscaled(image, by: 1).width == 8)
        #expect(ImageExporter.downscaled(image, by: 2).width == 8)
    }
}

private extension CGImage {
    /// Non-throwing on purpose: #require only unwraps the optional.
    func pixelRed(atX x: Int, y: Int) -> UInt8? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { return nil }
        context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        return bytes[(y * width + x) * 4]
    }
}

private func makeSolidImage(width: Int, height: Int) throws -> CGImage {
    // sRGB so the fill→makeImage→read round-trip is byte-exact.
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(colorSpace: colorSpace, components: [0.2, 0.4, 0.8, 1])!)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}
