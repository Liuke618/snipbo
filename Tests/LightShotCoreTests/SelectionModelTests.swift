import CoreGraphics
import Testing
@testable import LightShotCore

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
}
