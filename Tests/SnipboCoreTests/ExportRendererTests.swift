import CoreGraphics
import Testing
@testable import SnipboCore

@Suite("ExportRendererTests")
struct ExportRendererTests {
    @Test func testNoOptionsReturnsTheSameImage() throws {
        let image = try makeImage(width: 20, height: 10, gray: 0.5)
        let output = try #require(ExportRenderer.apply(image, options: ExportAppearance()))
        #expect(output === image)
    }

    @Test func testBeautifyAddsPadding() throws {
        let image = try makeImage(width: 40, height: 30, gray: 0.2)
        let output = try #require(ExportRenderer.apply(
            image,
            options: ExportAppearance(
                beautify: BeautifyOptions(
                    padding: 10,
                    cornerRadius: 0,
                    background: .white,
                    shadow: false
                )
            )
        ))
        #expect(output.width == 60)
        #expect(output.height == 50)
    }

    @Test func testWatermarkAddsBrightPixels() throws {
        let image = try makeImage(width: 240, height: 120, gray: 0)
        let output = try #require(ExportRenderer.apply(
            image,
            options: ExportAppearance(
                watermark: WatermarkOptions(
                    text: "SNIPBO",
                    position: .bottomRight,
                    opacity: 1
                )
            )
        ))
        #expect(output.width == 240)
        #expect(output.height == 120)
        let before = try averageBrightness(image)
        let after = try averageBrightness(output)
        #expect(after > before)
    }

    @Test func testBeautifyBackgroundFillsPadding() throws {
        let image = try makeImage(width: 20, height: 20, gray: 0)
        let output = try #require(ExportRenderer.apply(
            image,
            options: ExportAppearance(
                beautify: BeautifyOptions(
                    padding: 8,
                    cornerRadius: 0,
                    background: .white,
                    shadow: false
                )
            )
        ))
        // The top-left padding pixel is background, not the black image.
        let brightness = try pixelBrightness(output, x: 1, y: output.height - 2)
        #expect(brightness > 0.9)
    }

    private func makeImage(width: Int, height: Int, gray: CGFloat) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func pixelBrightness(_ image: CGImage, x: Int, y: Int) throws -> Double {
        let context = try #require(CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let data = try #require(context.data)
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        let bytes = data.bindMemory(
            to: UInt8.self,
            capacity: image.width * image.height * 4
        )
        let index = (y * image.width + x) * 4
        return (Double(bytes[index]) + Double(bytes[index + 1]) + Double(bytes[index + 2])) / (3 * 255)
    }

    private func averageBrightness(_ image: CGImage) throws -> Double {
        let context = try #require(CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let data = try #require(context.data)
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        let bytes = data.bindMemory(
            to: UInt8.self,
            capacity: image.width * image.height * 4
        )
        var total: Double = 0
        for index in stride(from: 0, to: image.width * image.height * 4, by: 4) {
            total += Double(bytes[index]) + Double(bytes[index + 1]) + Double(bytes[index + 2])
        }
        return total / Double(image.width * image.height * 3 * 255)
    }
}
