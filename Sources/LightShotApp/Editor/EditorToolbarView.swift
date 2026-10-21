import AppKit

@MainActor
final class EditorToolbarView: NSView {
    private let segmented = NSSegmentedControl(labels: EditorTool.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    private let redoButton = NSButton(title: "Redo", target: nil, action: nil)
    private let onTool: (EditorTool) -> Void
    private let onUndo: () -> Void
    private let onRedo: () -> Void

    init(onTool: @escaping (EditorTool) -> Void, onUndo: @escaping () -> Void, onRedo: @escaping () -> Void) {
        self.onTool = onTool
        self.onUndo = onUndo
        self.onRedo = onRedo
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        segmented.target = self
        segmented.action = #selector(toolChanged)
        segmented.selectedSegment = 0
        undoButton.target = self
        undoButton.action = #selector(undo)
        redoButton.target = self
        redoButton.action = #selector(redo)

        let stack = NSStackView(views: [segmented, undoButton, redoButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func toolChanged() {
        let index = segmented.selectedSegment
        guard index >= 0, index < EditorTool.allCases.count else { return }
        onTool(EditorTool.allCases[index])
    }

    @objc private func undo() { onUndo() }
    @objc private func redo() { onRedo() }
}
