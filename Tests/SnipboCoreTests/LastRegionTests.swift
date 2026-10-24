import CoreGraphics
import Testing
@testable import SnipboCore

@Suite("LastRegionTests")
struct LastRegionTests {
    private let geometry = ScreenGeometry(
        displayID: 1,
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        backingScale: 2
    )

    private func region(
        displayID: CGDirectDisplayID = 1,
        rect: CGRect = CGRect(x: 100, y: 100, width: 300, height: 200),
        screenFrame: CGRect = CGRect(x: 0, y: 0, width: 1440, height: 900),
        backingScale: CGFloat = 2
    ) -> LastRegion {
        LastRegion(
            displayID: displayID,
            rect: rect,
            screenFrame: screenFrame,
            backingScale: backingScale
        )
    }

    @Test func testValidRegion() {
        #expect(region().isValid(for: geometry))
    }

    @Test func testRejectsDifferentDisplay() {
        #expect(!region(displayID: 2).isValid(for: geometry))
    }

    @Test func testRejectsChangedScreenFrame() {
        let changed = CGRect(x: 0, y: 0, width: 1280, height: 800)
        #expect(!region(screenFrame: changed).isValid(for: geometry))
    }

    @Test func testRejectsDifferentBackingScale() {
        #expect(!region(backingScale: 1).isValid(for: geometry))
    }

    @Test func testRejectsEmptyOrOutOfBoundsRect() {
        #expect(!region(rect: .zero).isValid(for: geometry))
        #expect(!region(rect: CGRect(x: 1400, y: 100, width: 100, height: 100)).isValid(for: geometry))
    }
}
