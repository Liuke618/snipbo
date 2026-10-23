import CoreGraphics
import Testing
@testable import LightShotCore

@Suite("WindowTargetTests")
struct WindowTargetTests {
    @Test func testDisplayTitleCombinesApplicationAndWindowTitle() {
        let target = WindowTarget(
            windowID: 42,
            title: "Document",
            applicationName: "Example",
            frame: CGRect(x: 10, y: 20, width: 300, height: 200)
        )
        #expect(target.displayTitle == "Example — Document")
    }

    @Test func testDisplayTitleFallsBackToApplicationWhenTitleIsEmpty() {
        let target = WindowTarget(
            windowID: 42,
            title: "   ",
            applicationName: "Example",
            frame: CGRect(x: 10, y: 20, width: 300, height: 200)
        )
        #expect(target.displayTitle == "Example")
    }
}
