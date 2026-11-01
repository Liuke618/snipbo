import CoreGraphics
import Testing
@testable import SnipboCore

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

    @Test func testLockTargetPicksTheSmallestWindowContainingThePoint() {
        let background = WindowTarget(
            windowID: 1,
            title: "Background",
            applicationName: "Browser",
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
        let panel = WindowTarget(
            windowID: 2,
            title: "Panel",
            applicationName: "Tool",
            frame: CGRect(x: 100, y: 100, width: 200, height: 150)
        )
        // A point inside both locks onto the small window on top; a point in
        // the large window only locks onto the large one.
        #expect(WindowTarget.lockTarget(at: CGPoint(x: 150, y: 150), in: [background, panel]) == panel)
        #expect(WindowTarget.lockTarget(at: CGPoint(x: 50, y: 50), in: [background, panel]) == background)
        // Edges count as inside, matching CGRect.contains.
        #expect(WindowTarget.lockTarget(at: CGPoint(x: 100, y: 100), in: [background, panel]) == panel)
        // No window under the point locks nothing.
        #expect(WindowTarget.lockTarget(at: CGPoint(x: 1500, y: 1500), in: [background, panel]) == nil)
        #expect(WindowTarget.lockTarget(at: .zero, in: []) == nil)
    }
}
