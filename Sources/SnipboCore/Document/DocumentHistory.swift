import Foundation

public final class DocumentHistory {
    private var undoStack: [DocumentState] = []
    private var redoStack: [DocumentState] = []
    public let limit: Int

    public init(limit: Int = 50) {
        self.limit = max(1, limit)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoDepth: Int { undoStack.count }

    public func record(_ state: DocumentState) {
        undoStack.append(state)
        if undoStack.count > limit {
            undoStack.removeFirst(undoStack.count - limit)
        }
        redoStack.removeAll()
    }

    public func undo(current: DocumentState) -> DocumentState? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    public func redo(current: DocumentState) -> DocumentState? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }

    /// Drops all undo/redo state, used when the document is replaced wholesale
    /// (image resize) and previous states no longer apply.
    public func reset() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
