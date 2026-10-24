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
    /// Image-based tool segments when all Lucide icons loaded; otherwise the
    /// label-based fallback (unbundled harness contexts).
    private let segmented: NSSegmentedControl
    private let colorWell = NSColorWell()
    private let widthSlider = NSSlider(value: 3, minValue: 1, maxValue: 24, target: nil, action: nil)
    private let recognizeButton = NSButton(
        image: EditorToolbarView.icon("scan-text") ?? NSImage(
            systemSymbolName: "text.viewfinder",
            accessibilityDescription: "Recognize Text"
        ) ?? NSImage(),
        target: nil,
        action: nil
    )
    private let pinButton = NSButton(
        image: EditorToolbarView.icon("pin") ?? NSImage(
            systemSymbolName: "pin",
            accessibilityDescription: "Pin"
        ) ?? NSImage(),
        target: nil,
        action: nil
    )
    private let undoButton = NSButton(
        image: EditorToolbarView.icon("undo-2") ?? NSImage(),
        target: nil,
        action: nil
    )
    private let redoButton = NSButton(
        image: EditorToolbarView.icon("redo-2") ?? NSImage(),
        target: nil,
        action: nil
    )
    private let copyButton = NSButton(
        image: EditorToolbarView.icon("copy") ?? NSImage(),
        target: nil,
        action: nil
    )
    private let saveButton = NSButton(
        image: EditorToolbarView.icon("save") ?? NSImage(),
        target: nil,
        action: nil
    )
    private let closeButton = NSButton(
        image: EditorToolbarView.icon("x") ?? NSImage(),
        target: nil,
        action: nil
    )

    /// Loads a bundled Lucide SVG as a monochrome template image.
    private static func icon(_ name: String, size: CGFloat = 16) -> NSImage? {
        guard let url = Bundle.main.url(
            forResource: name,
            withExtension: "svg",
            subdirectory: "Icons"
        ), let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: size, height: size)
        return image
    }

    private let onTool: (EditorTool) -> Void
    private let onUndo: () -> Void
    private let onRedo: () -> Void
    private let onColor: (RGBA) -> Void
    private let onWidth: (CGFloat) -> Void
    private let onRecognize: () -> Void
    private let onPin: () -> Void
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
        onPin: @escaping () -> Void,
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
        self.onPin = onPin
        self.onCopy = onCopy
        self.onSave = onSave
        self.onClose = onClose

        // Image-based tool segments with hover tooltips when every Lucide
        // icon is bundled; label fallback keeps the harness usable.
        let toolImages = EditorTool.allCases.compactMap { EditorToolbarView.icon($0.iconName, size: 15) }
        let control: NSSegmentedControl
        if toolImages.count == EditorTool.allCases.count {
            control = NSSegmentedControl(images: toolImages, trackingMode: .selectOne, target: nil, action: nil)
            for (index, tool) in EditorTool.allCases.enumerated() {
                control.setToolTip(tool.title, forSegment: index)
                control.setWidth(30, forSegment: index)
            }
        } else {
            control = NSSegmentedControl(labels: EditorTool.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
        }
        segmented = control
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // Small controls keep every group inside the editor's default
        // 1000-point width instead of forcing the window wider.
        for control in [segmented, colorWell, widthSlider, recognizeButton, pinButton, undoButton, redoButton, copyButton, saveButton, closeButton] {
            control.controlSize = .small
        }
        // Icon-only buttons carry their meaning in the hover tooltip.
        for (button, tooltip) in [
            (undoButton, L10n.tr("Undo", "撤销")),
            (redoButton, L10n.tr("Redo", "重做")),
            (copyButton, L10n.tr("Copy", "复制")),
            (saveButton, L10n.tr("Save", "保存")),
            (closeButton, L10n.tr("Close", "关闭")),
        ] {
            button.imagePosition = .imageOnly
            button.toolTip = tooltip
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
        recognizeButton.toolTip = L10n.tr("Recognize text and barcodes", "识别文字与条码")
        recognizeButton.target = self
        recognizeButton.action = #selector(recognizeAction)
        pinButton.imagePosition = .imageOnly
        pinButton.toolTip = L10n.tr("Pin as floating window (⌘P)", "贴图置顶 (⌘P)")
        pinButton.target = self
        pinButton.action = #selector(pinAction)

        let stack = NSStackView(views: [
            segmented, colorWell, widthSlider, recognizeButton, pinButton, undoButton, redoButton, copyButton, saveButton, closeButton,
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
    @objc private func pinAction() { onPin() }
    @objc private func undo() { onUndo() }
    @objc private func redo() { onRedo() }
    @objc private func copyAction() { onCopy() }
    @objc private func saveAction() { onSave() }
    @objc private func closeAction() { onClose() }
}
