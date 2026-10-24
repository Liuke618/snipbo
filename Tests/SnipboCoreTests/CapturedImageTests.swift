import CoreGraphics
import Foundation
import Testing
@testable import SnipboCore

@Suite("CapturedImageTests")
struct CapturedImageTests {
    @Test func testCropUsesBackingScale() throws {
        let image = try makeImage(width: 100, height: 100)
        let geometry = ScreenGeometry(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 50, height: 50),
            backingScale: 2
        )
        let captured = CapturedImage(image: image, geometry: geometry, capturedAt: Date())
        let cropped = try #require(
            captured.cropped(toLocalPoints: CGRect(x: 10, y: 10, width: 20, height: 20))
        )
        #expect(cropped.width == 40)
        #expect(cropped.height == 40)
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}
