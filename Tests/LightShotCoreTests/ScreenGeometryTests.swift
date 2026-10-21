import CoreGraphics
import Testing
@testable import LightShotCore

@Suite("ScreenGeometryTests")
struct ScreenGeometryTests {
    @Test func testPixelRectOnTwoXScreen() {
        let geometry = ScreenGeometry(displayID: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), backingScale: 2)
        let pixels = geometry.pixelRect(fromLocalPoints: CGRect(x: 10, y: 20, width: 30, height: 40))
        #expect(pixels == CGRect(x: 20, y: 40, width: 60, height: 80))
    }

    @Test func testPixelRectRoundsToWholePixels() {
        let geometry = ScreenGeometry(displayID: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), backingScale: 1.5)
        let pixels = geometry.pixelRect(fromLocalPoints: CGRect(x: 1, y: 1, width: 3, height: 3))
        #expect(pixels == CGRect(x: 1, y: 1, width: 5, height: 5))
    }

    @Test func testLocalPointRoundTrip() {
        let geometry = ScreenGeometry(displayID: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), backingScale: 2)
        let original = CGRect(x: 10, y: 20, width: 30, height: 40)
        let pixels = geometry.pixelRect(fromLocalPoints: original)
        #expect(geometry.localPointRect(fromPixelRect: pixels) == original)
    }
}
