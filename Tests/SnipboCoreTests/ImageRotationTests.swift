import CoreGraphics
import Testing
@testable import SnipboCore

@Suite("ImageRotationTests")
struct ImageRotationTests {
    @Test func testRotationSwapsDimensionsAndRoundTrips() throws {
        let image = try makeImage(width: 7, height: 3)
        let clockwise = try #require(ImageRotation.rotated90(image, clockwise: true))
        #expect(clockwise.width == 3)
        #expect(clockwise.height == 7)

        let restored = try #require(ImageRotation.rotated90(clockwise, clockwise: false))
        #expect(restored.width == 7)
        #expect(restored.height == 3)
        #expect(try pixels(of: restored) == pixels(of: image))
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let data = try #require(context.data)
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                bytes[index] = UInt8((x * 37 + y * 11) % 255)
                bytes[index + 1] = UInt8((x * 13 + y * 53) % 255)
                bytes[index + 2] = UInt8((x * 71 + y * 7) % 255)
                bytes[index + 3] = 255
            }
        }
        return try #require(context.makeImage())
    }

    private func pixels(of image: CGImage) throws -> [UInt8] {
        let context = try #require(CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        let data = try #require(context.data)
        return Array(UnsafeBufferPointer(
            start: data.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4),
            count: image.width * image.height * 4
        ))
    }
}
