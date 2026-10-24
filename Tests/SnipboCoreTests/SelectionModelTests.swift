import CoreGraphics
import Testing
@testable import SnipboCore

@Suite("SelectionModelTests")
struct SelectionModelTests {
    private let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)

    @Test func testHandleHitTesting() {
        let model = SelectionModel(rect: CGRect(x: 50, y: 50, width: 100, height: 80))
        #expect(model.handle(at: CGPoint(x: 50, y: 50), tolerance: 6) == .topLeft)
        #expect(model.handle(at: CGPoint(x: 150, y: 130), tolerance: 6) == .bottomRight)
        #expect(model.handle(at: CGPoint(x: 100, y: 90), tolerance: 6) == .inside)
        #expect(model.handle(at: CGPoint(x: 10, y: 10), tolerance: 6) == nil)
    }

    @Test func testDraggingTopLeftClampsToBounds() {
        var model = SelectionModel(rect: CGRect(x: 50, y: 50, width: 100, height: 80))
        model.drag(handle: .topLeft, to: CGPoint(x: -20, y: -10), constrainedTo: bounds)
        #expect(model.rect == CGRect(x: 0, y: 0, width: 150, height: 130))
    }

    @Test func testDraggingInsideMovesSelection() {
        var model = SelectionModel(rect: CGRect(x: 50, y: 50, width: 100, height: 80))
        model.drag(handle: .inside, to: CGPoint(x: 180, y: 190), constrainedTo: bounds)
        #expect(model.rect == CGRect(x: 100, y: 120, width: 100, height: 80))
    }

    @Test func testNudgeAndResize() {
        var model = SelectionModel(rect: CGRect(x: 50, y: 50, width: 100, height: 80))
        model.nudge(dx: 5, dy: -5, resize: false, constrainedTo: bounds)
        #expect(model.rect == CGRect(x: 55, y: 45, width: 100, height: 80))
        model.nudge(dx: 10, dy: 0, resize: true, constrainedTo: bounds)
        #expect(model.rect == CGRect(x: 55, y: 45, width: 110, height: 80))
    }

    @Test func testDraggingTopPastBoundsKeepsMinimumSizeInsideBounds() {
        var model = SelectionModel(rect: CGRect(x: 50, y: 50, width: 100, height: 80))
        model.drag(handle: .top, to: CGPoint(x: 100, y: 200), constrainedTo: bounds)
        #expect(model.rect == CGRect(x: 50, y: 199, width: 100, height: 1))
    }

    @Test func testDraggingLeftPastBoundsKeepsMinimumSizeInsideBounds() {
        var model = SelectionModel(rect: CGRect(x: 50, y: 50, width: 100, height: 80))
        model.drag(handle: .left, to: CGPoint(x: 200, y: 50), constrainedTo: bounds)
        #expect(model.rect == CGRect(x: 199, y: 50, width: 1, height: 80))
    }

    @Test func testZeroDeltaResizeNudgeLeavesRectUnchanged() {
        var model = SelectionModel(rect: CGRect(x: 50, y: 50, width: 100, height: 80))
        model.nudge(dx: 0, dy: 0, resize: true, constrainedTo: bounds)
        #expect(model.rect == CGRect(x: 50, y: 50, width: 100, height: 80))
    }

    @Test func testResizeLeftEdgeMovesLeft() {
        var model = SelectionModel(rect: CGRect(x: 50, y: 50, width: 100, height: 80))
        model.resize(edge: .left, by: 10, constrainedTo: bounds)
        #expect(model.rect == CGRect(x: 40, y: 50, width: 110, height: 80))
    }

    @Test func testResizeRightEdgeMovesRight() {
        var model = SelectionModel(rect: CGRect(x: 50, y: 50, width: 100, height: 80))
        model.resize(edge: .right, by: 10, constrainedTo: bounds)
        #expect(model.rect == CGRect(x: 50, y: 50, width: 110, height: 80))
    }

    @Test func testResizeTopEdgeMovesUp() {
        var model = SelectionModel(rect: CGRect(x: 50, y: 50, width: 100, height: 80))
        model.resize(edge: .top, by: 10, constrainedTo: bounds)
        #expect(model.rect == CGRect(x: 50, y: 40, width: 100, height: 90))
    }

    @Test func testResizeBottomEdgeMovesDown() {
        var model = SelectionModel(rect: CGRect(x: 50, y: 50, width: 100, height: 80))
        model.resize(edge: .bottom, by: 10, constrainedTo: bounds)
        #expect(model.rect == CGRect(x: 50, y: 50, width: 100, height: 90))
    }

    @Test func testResizeAtBoundsDoesNotLeaveTheScreen() {
        var left = SelectionModel(rect: CGRect(x: 0, y: 50, width: 100, height: 80))
        left.resize(edge: .left, by: 10, constrainedTo: bounds)
        #expect(left.rect == CGRect(x: 0, y: 50, width: 100, height: 80))

        var right = SelectionModel(rect: CGRect(x: 100, y: 50, width: 100, height: 80))
        right.resize(edge: .right, by: 10, constrainedTo: bounds)
        #expect(right.rect == CGRect(x: 100, y: 50, width: 100, height: 80))

        var top = SelectionModel(rect: CGRect(x: 50, y: 0, width: 100, height: 80))
        top.resize(edge: .top, by: 10, constrainedTo: bounds)
        #expect(top.rect == CGRect(x: 50, y: 0, width: 100, height: 80))

        var bottom = SelectionModel(rect: CGRect(x: 50, y: 120, width: 100, height: 80))
        bottom.resize(edge: .bottom, by: 10, constrainedTo: bounds)
        #expect(bottom.rect == CGRect(x: 50, y: 120, width: 100, height: 80))
    }

    @Test func testResizeStopsAtMinimumSize() {
        var left = SelectionModel(rect: CGRect(x: 50, y: 50, width: 100, height: 80))
        left.resize(edge: .left, by: -200, constrainedTo: bounds)
        #expect(left.rect == CGRect(x: 149, y: 50, width: 1, height: 80))

        var right = SelectionModel(rect: CGRect(x: 50, y: 50, width: 100, height: 80))
        right.resize(edge: .right, by: -200, constrainedTo: bounds)
        #expect(right.rect == CGRect(x: 50, y: 50, width: 1, height: 80))

        var top = SelectionModel(rect: CGRect(x: 50, y: 50, width: 100, height: 80))
        top.resize(edge: .top, by: -200, constrainedTo: bounds)
        #expect(top.rect == CGRect(x: 50, y: 129, width: 100, height: 1))

        var bottom = SelectionModel(rect: CGRect(x: 50, y: 50, width: 100, height: 80))
        bottom.resize(edge: .bottom, by: -200, constrainedTo: bounds)
        #expect(bottom.rect == CGRect(x: 50, y: 50, width: 100, height: 1))
    }
}
