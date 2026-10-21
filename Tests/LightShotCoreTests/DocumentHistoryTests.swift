import CoreGraphics
import Testing
@testable import LightShotCore

@Suite("DocumentHistoryTests")
struct DocumentHistoryTests {
    private let stateA = DocumentState(cropRect: CGRect(x: 0, y: 0, width: 100, height: 100), annotations: [])
    private let stateB = DocumentState(
        cropRect: CGRect(x: 0, y: 0, width: 100, height: 100),
        annotations: [
            Annotation(
                kind: .rectangle,
                geometry: .rect(CGRect(x: 1, y: 1, width: 10, height: 10)),
                style: AnnotationStyle(),
                zIndex: 1
            ),
        ]
    )

    @Test func testUndoAndRedo() {
        let history = DocumentHistory(limit: 10)
        history.record(stateA)
        let undone = history.undo(current: stateB)
        #expect(undone == stateA)
        let redone = history.redo(current: stateA)
        #expect(redone == stateB)
    }

    @Test func testNewRecordClearsRedo() {
        let history = DocumentHistory(limit: 10)
        history.record(stateA)
        _ = history.undo(current: stateB)
        history.record(stateA)
        #expect(!history.canRedo)
    }

    @Test func testHistoryLimitDropsOldest() {
        let history = DocumentHistory(limit: 2)
        let s0 = DocumentState(cropRect: .zero, annotations: [])
        let s1 = DocumentState(cropRect: CGRect(x: 1, y: 1, width: 1, height: 1), annotations: [])
        let s2 = DocumentState(cropRect: CGRect(x: 2, y: 2, width: 1, height: 1), annotations: [])
        let current = DocumentState(cropRect: CGRect(x: 3, y: 3, width: 1, height: 1), annotations: [])
        history.record(s0)
        history.record(s1)
        history.record(s2)
        #expect(history.undoDepth == 2)
        let first = history.undo(current: current)
        #expect(first?.cropRect.origin.x == 2)
        let second = history.undo(current: first ?? current)
        #expect(second?.cropRect.origin.x == 1)
        let third = history.undo(current: second ?? current)
        #expect(third == nil)
        #expect(history.canUndo == false)
        #expect(history.canRedo == true)
    }
}
