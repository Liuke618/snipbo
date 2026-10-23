import AppKit
import LightShotCore

extension NSColor {
    var rgbaValue: RGBA {
        let converted = usingColorSpace(.sRGB) ?? self
        return RGBA(
            red: converted.redComponent,
            green: converted.greenComponent,
            blue: converted.blueComponent,
            alpha: converted.alphaComponent
        )
    }
}

@MainActor
final class EditorToolbarView: NSView {
    private let segmented = NSSegmentedControl(labels: EditorTool.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let colorWell = NSColorWell()
    private let widthSlider = NSSlider(value: 3, minValue: 1, maxValue: 24, target: nil, action: nil)
    private let recognizeButton = NSButton(
        image: NSImage(
            systemSymbolName: "text.viewfinder",
            accessibilityDescription: "Recognize Text"
        ) ?? NSImage(),
        target: nil,
        action: nil
    )
    private let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    private let redoButton = NSButton(title: "Redo", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)

    private let onTool: (EditorTool) -> Void
    private let onUndo: () -> Void
    private let onRedo: () -> Void
    private let onColor: (RGBA) -> Void
    private let onWidth: (CGFloat) -> Void
    private let onRecognize: () -> Void
    private let onCopy: () -> Void
    private let onSave: () -> Void
    private let onClose: () -> Void

    init(
        onTool: @escaping (EditorTool) -> Void,
        onUndo: @escaping () -> Void,
        onRedo: @escaping () -> Void,
        onColor: @escaping (RGBA) -> Void,
        onWidth: @escaping (CGFloat) -> Void,
        onRecognize: @escaping () -> Void,
        onCopy: @escaping () -> Void,
        onSave: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.onTool = onTool
        self.onUndo = onUndo
        self.onRedo = onRedo
        self.onColor = onColor
        self.onWidth = onWidth
        self.onRecognize = onRecognize
        self.onCopy = onCopy
        self.onSave = onSave
        self.onClose = onClose
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // Small controls keep every group inside the editor's default
        // 1000-point width instead of forcing the window wider.
        for control in [segmented, colorWell, widthSlider, recognizeButton, undoButton, redoButton, copyButton, saveButton, closeButton] {
            control.controlSize = .small
        }
        segmented.selectedSegment = 0
        segmented.target = self
        segmented.action = #selector(toolChanged)
        colorWell.target = self
        colorWell.action = #selector(colorChanged)
        widthSlider.target = self
        widthSlider.action = #selector(widthChanged)
        undoButton.target = self
        undoButton.action = #selector(undo)
        redoButton.target = self
        redoButton.action = #selector(redo)
        copyButton.target = self
        copyButton.action = #selector(copyAction)
        saveButton.target = self
        saveButton.action = #selector(saveAction)
        closeButton.target = self
        closeButton.action = #selector(closeAction)
        recognizeButton.imagePosition = .imageOnly
        recognizeButton.toolTip = "Recognize text and barcodes"
        recognizeButton.target = self
        recognizeButton.action = #selector(recognizeAction)

        let stack = NSStackView(views: [
            segmented, colorWell, widthSlider, recognizeButton, undoButton, redoButton, copyButton, saveButton, closeButton,
        ])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 40),
            widthSlider.widthAnchor.constraint(equalToConstant: 90),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func toolChanged() {
        let index = segmented.selectedSegment
        guard index >= 0, index < EditorTool.allCases.count else { return }
        onTool(EditorTool.allCases[index])
    }

    func setRecognizing(_ recognizing: Bool) {
        recognizeButton.isEnabled = !recognizing
    }

    @objc private func colorChanged() { onColor(colorWell.color.rgbaValue) }
    @objc private func widthChanged() { onWidth(widthSlider.doubleValue) }
    @objc private func recognizeAction() { onRecognize() }
    @objc private func undo() { onUndo() }
    @objc private func redo() { onRedo() }
    @objc private func copyAction() { onCopy() }
    @objc private func saveAction() { onSave() }
    @objc private func closeAction() { onClose() }
}
