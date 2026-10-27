import CoreGraphics
import ImageIO
import Testing
@testable import SnipboCore

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

    @Test func testHEICAndAVIFExportDecodes() throws {
        let image = try makeSolidImage(width: 24, height: 16)
        for format in [ImageFormat.heic, .avif] {
            let data = try #require(
                ImageExporter.data(from: image, format: format, quality: 0.8),
                "\(format) encoding returned nil"
            )
            #expect(!data.isEmpty)
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(decoded.width == 24)
            #expect(decoded.height == 16)
        }
    }

    @Test func testTargetSizeLowersLossyQuality() throws {
        let image = try makeNoiseImage(width: 100, height: 100)
        let full = try #require(
            ImageExporter.data(from: image, format: .jpeg, quality: 1)
        )
        let target = 8_000
        let capped = try #require(
            ImageExporter.data(
                from: image,
                format: .jpeg,
                quality: 1,
                targetBytes: target
            )
        )
        #expect(capped.count <= target)
        #expect(capped.count < full.count)
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

/// Deterministic per-pixel noise so lossy target-size search has real data to
/// compress instead of a uniform color that always fits.
private func makeNoiseImage(width: Int, height: Int) throws -> CGImage {
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let bytes = try #require(context.data).bindMemory(
        to: UInt8.self,
        capacity: width * height * 4
    )
    var seed: UInt32 = 0x1234_5678
    for pixel in 0..<(width * height) {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        let index = pixel * 4
        bytes[index] = UInt8(truncatingIfNeeded: seed >> 16)
        bytes[index + 1] = UInt8(truncatingIfNeeded: seed >> 8)
        bytes[index + 2] = UInt8(truncatingIfNeeded: seed)
        bytes[index + 3] = 255
    }
    return try #require(context.makeImage())
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
