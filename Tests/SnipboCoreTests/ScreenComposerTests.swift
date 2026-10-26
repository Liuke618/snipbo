import CoreGraphics
import Testing
@testable import SnipboCore

@Suite("ScreenComposerTests")
struct ScreenComposerTests {
    @Test func testEmptyInputProducesNoImage() {
        #expect(ScreenComposer.compose([]) == nil)
    }

    @Test func testEffectiveScaleKeepsNormalLayoutAtNativeScale() {
        let union = CGRect(x: 0, y: 0, width: 2_000, height: 1_000)
        #expect(ScreenComposer.effectiveScale(forUnion: union, maxBackingScale: 2) == 2)
    }

    @Test func testEffectiveScaleCapsHugeUnionWithinPixelBudget() {
        let union = CGRect(x: 0, y: 0, width: 20_000, height: 10_000)
        let scale = ScreenComposer.effectiveScale(forUnion: union, maxBackingScale: 2)
        #expect(scale < 2)
        let pixels = CGFloat(union.width) * CGFloat(union.height) * scale * scale
        #expect(pixels <= CGFloat(ScreenComposer.maxCompositePixels) + 1)
    }

    @Test func testComposeWithScaleReportsNativeScale() throws {
        let image = try makeSolidImage(red: 1, green: 0, blue: 0, width: 200, height: 100)
        let composition = try #require(ScreenComposer.composeWithScale([
            ScreenSlice(
                image: image,
                frame: CGRect(x: 0, y: 0, width: 100, height: 50),
                backingScale: 2
            ),
        ]))
        #expect(composition.scale == 2)
        #expect(composition.image.width == 200)
        #expect(composition.image.height == 100)
    }

    @Test func testComposeWithScaleHonorsPixelBudget() throws {
        let image = try makeSolidImage(red: 1, green: 0, blue: 0, width: 200, height: 200)
        let composition = try #require(ScreenComposer.composeWithScale([
            ScreenSlice(
                image: image,
                frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                backingScale: 2
            ),
        ], pixelBudget: 10_000))
        #expect(composition.scale == 1)
        #expect(composition.image.width == 100)
        #expect(composition.image.height == 100)
    }

    @Test func testSingleSliceKeepsNativePixelSize() throws {
        let image = try makeSolidImage(red: 1, green: 0, blue: 0, width: 200, height: 100)
        let composed = try #require(ScreenComposer.compose([
            ScreenSlice(
                image: image,
                frame: CGRect(x: 0, y: 0, width: 100, height: 50),
                backingScale: 2
            ),
        ]))
        #expect(composed.width == 200)
        #expect(composed.height == 100)
    }

    @Test func testHorizontalScreensUseLargestBackingScale() throws {
        let red = try makeSolidImage(red: 1, green: 0, blue: 0, width: 100, height: 100)
        let blue = try makeSolidImage(red: 0, green: 0, blue: 1, width: 50, height: 100)
        let composed = try #require(ScreenComposer.compose([
            ScreenSlice(
                image: red,
                frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                backingScale: 1
            ),
            ScreenSlice(
                image: blue,
                frame: CGRect(x: 100, y: 0, width: 50, height: 100),
                backingScale: 2
            ),
        ]))
        #expect(composed.width == 300)
        #expect(composed.height == 200)
        let left = try pixel(composed, x: 50, y: 50)
        let right = try pixel(composed, x: 250, y: 50)
        #expect(left.red > 200 && left.blue < 50)
        #expect(right.blue > 200 && right.red < 50)
    }

    @Test func testVerticalScreensKeepTopScreenAtTheTop() throws {
        let red = try makeSolidImage(red: 1, green: 0, blue: 0, width: 100, height: 50)
        let blue = try makeSolidImage(red: 0, green: 0, blue: 1, width: 100, height: 50)
        let composed = try #require(ScreenComposer.compose([
            ScreenSlice(
                image: red,
                frame: CGRect(x: 0, y: 0, width: 100, height: 50),
                backingScale: 1
            ),
            ScreenSlice(
                image: blue,
                frame: CGRect(x: 0, y: 50, width: 100, height: 50),
                backingScale: 1
            ),
        ]))
        #expect(composed.width == 100)
        #expect(composed.height == 100)
        let top = try pixel(composed, x: 50, y: 5)
        let bottom = try pixel(composed, x: 50, y: 95)
        #expect(top.blue > 200 && top.red < 50)
        #expect(bottom.red > 200 && bottom.blue < 50)
    }
}

private func makeSolidImage(
    red: CGFloat,
    green: CGFloat,
    blue: CGFloat,
    width: Int,
    height: Int
) throws -> CGImage {
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}

/// Reads a pixel with a top-left origin.
private func pixel(_ image: CGImage, x: Int, y: Int) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
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
    let index = (y * width + x) * 4
    return (bytes[index], bytes[index + 1], bytes[index + 2])
}
