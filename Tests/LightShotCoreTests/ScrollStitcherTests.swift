import CoreGraphics
import Testing
@testable import LightShotCore

@Suite("ScrollStitcherTests")
struct ScrollStitcherTests {
    @Test func testInitialImageIsKeptWhenUnderLimit() throws {
        let image = try makeRows([0, 1, 2, 3])
        let result = try #require(ScrollStitcher.makeInitial(image: image, maxHeight: 10))
        #expect(result.image.height == 4)
        #expect(result.appendedRows == 0)
        #expect(!result.reachedLimit)
    }

    @Test func testInitialImageIsTruncatedAtLimit() throws {
        let image = try makeRows([0, 1, 2, 3, 4])
        let result = try #require(ScrollStitcher.makeInitial(image: image, maxHeight: 3))
        #expect(result.image.height == 3)
        #expect(result.reachedLimit)
    }

    @Test func testAppendSkipsOverlapAndKeepsTopImage() throws {
        let initial = try makeRows([0, 1, 2, 3])
        let frame = try makeRows([4, 5, 6, 7])
        let result = try #require(ScrollStitcher.append(
            composite: initial,
            frame: frame,
            offset: 2,
            maxHeight: 100
        ))
        #expect(result.image.height == 6)
        #expect(result.appendedRows == 2)
        #expect(!result.reachedLimit)
        #expect(try rows(of: result.image) == [0, 1, 2, 3, 6, 7])
    }

    @Test func testAppendStopsAtMaximumHeight() throws {
        let initial = try makeRows([0, 1, 2, 3])
        let frame = try makeRows([4, 5, 6, 7])
        let result = try #require(ScrollStitcher.append(
            composite: initial,
            frame: frame,
            offset: 1,
            maxHeight: 6
        ))
        #expect(result.image.height == 6)
        #expect(result.appendedRows == 2)
        #expect(result.reachedLimit)
        #expect(try rows(of: result.image) == [0, 1, 2, 3, 5, 6])
    }

    @Test func testInvalidOffsetsAndWidthsAreIgnored() throws {
        let initial = try makeRows([0, 1, 2, 3])
        let frame = try makeRows([4, 5, 6, 7])
        #expect(ScrollStitcher.append(composite: initial, frame: frame, offset: 0, maxHeight: 100) == nil)
        #expect(ScrollStitcher.append(composite: initial, frame: frame, offset: -1, maxHeight: 100) == nil)
        #expect(ScrollStitcher.append(composite: initial, frame: frame, offset: 4, maxHeight: 100) == nil)
        let narrow = try makeRows([8, 9], width: 2)
        #expect(ScrollStitcher.append(composite: initial, frame: narrow, offset: 1, maxHeight: 100) == nil)
    }
}

// sRGB everywhere: a DeviceRGB fill→makeImage→draw round-trip perturbs low
// byte values by ~1 (color matching), which would break exact row assertions.
private let rowColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

private func makeRows(_ values: [UInt8], width: Int = 4) throws -> CGImage {
    let height = values.count
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: rowColorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    for (row, value) in values.enumerated() {
        context.setFillColor(CGColor(
            colorSpace: rowColorSpace,
            components: [CGFloat(value) / 255, 0, 0, 1]
        )!)
        // CGContext is bottom-left oriented; row 0 of the resulting CGImage is
        // the top row, so draw the first value at the top.
        context.fill(CGRect(x: 0, y: height - row - 1, width: width, height: 1))
    }
    return try #require(context.makeImage())
}

private func rows(of image: CGImage) throws -> [UInt8] {
    let width = image.width
    let height = image.height
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: rowColorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let data = try #require(context.data)
    let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
    return (0..<height).map { bytes[$0 * width * 4] }
}
