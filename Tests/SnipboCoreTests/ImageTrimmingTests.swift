import CoreGraphics
import Testing
@testable import SnipboCore

@Suite("ImageTrimmingTests")
struct ImageTrimmingTests {
    @Test func testTrimsTransparentMarginsToOpaqueBounds() throws {
        let image = try makeWindowImage(width: 40, height: 20, margin: 4)
        let trimmed = try #require(ImageTrimming.trimmedToOpaqueBounds(image))
        #expect(trimmed.width == 32)
        #expect(trimmed.height == 12)
    }

    @Test func testFullyOpaqueImageIsNotTrimmed() throws {
        let image = try makeWindowImage(width: 10, height: 10, margin: 0)
        #expect(ImageTrimming.trimmedToOpaqueBounds(image) == nil)
    }

    @Test func testFullyTransparentImageIsNotTrimmed() throws {
        let image = try makeWindowImage(width: 10, height: 10, margin: nil)
        #expect(ImageTrimming.trimmedToOpaqueBounds(image) == nil)
    }

    @Test func testImageWithoutAlphaIsNotTrimmed() throws {
        let image = try makeOpaqueNoAlphaImage(width: 8, height: 6)
        #expect(ImageTrimming.trimmedToOpaqueBounds(image) == nil)
    }
}

/// Renders a window-like image: an opaque rectangle with `margin` transparent
/// pixels on every side, or fully transparent when margin is nil.
private func makeWindowImage(width: Int, height: Int, margin: Int?) throws -> CGImage {
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    if let margin {
        context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [0.9, 0.2, 0.2, 1])!)
        context.fill(CGRect(x: margin, y: margin, width: width - margin * 2, height: height - margin * 2))
    }
    return try #require(context.makeImage())
}

private func makeOpaqueNoAlphaImage(width: Int, height: Int) throws -> CGImage {
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}
