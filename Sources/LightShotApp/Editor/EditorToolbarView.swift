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

/// Shottr-style editor toolbar that lives in the window's title bar as two
/// accessories: leading (copy / save / pin + the tool segments) and trailing
/// (recognize, undo/redo, color, width, and live size/zoom readouts).
@MainActor
final class EditorToolbarView: NSObject {
    let leadingAccessory: NSTitlebarAccessoryViewController
    let trailingAccessory: NSTitlebarAccessoryViewController

    /// Image-based tool segments when all Lucide icons loaded; otherwise the
    /// label-based fallback (unbundled harness contexts).
    private let segmented: NSSegmentedControl
    private let colorWell = NSColorWell()
    private let widthSlider = NSSlider(value: 3, minValue: 1, maxValue: 24, target: nil, action: nil)
    private let recognizeButton = NSButton()
    private let pinButton = NSButton()
    private let copyButton = NSButton()
    private let saveButton = NSButton()
    private let undoButton = NSButton()
    private let redoButton = NSButton()
    private let sizeLabel = NSTextField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "")

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

    init(
        onTool: @escaping (EditorTool) -> Void,
        onUndo: @escaping () -> Void,
        onRedo: @escaping () -> Void,
        onColor: @escaping (RGBA) -> Void,
        onWidth: @escaping (CGFloat) -> Void,
        onRecognize: @escaping () -> Void,
        onPin: @escaping () -> Void,
        onCopy: @escaping () -> Void,
        onSave: @escaping () -> Void
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

        // Image-based tool segments with hover tooltips showing the single-key
        // shortcut ("Arrow (A)") when every Lucide icon is bundled; the label
        // fallback keeps unbundled harness contexts usable.
        let toolImages = EditorTool.allCases.compactMap { EditorToolbarView.icon($0.iconName, size: 15) }
        let control: NSSegmentedControl
        if toolImages.count == EditorTool.allCases.count {
            control = NSSegmentedControl(images: toolImages, trackingMode: .selectOne, target: nil, action: nil)
            for (index, tool) in EditorTool.allCases.enumerated() {
                let tooltip = tool.hotKeyLetter.map { "\(tool.title) (\($0.uppercased()))" } ?? tool.title
                control.setToolTip(tooltip, forSegment: index)
                control.setWidth(30, forSegment: index)
            }
        } else {
            control = NSSegmentedControl(labels: EditorTool.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
        }
        segmented = control

        for button in [recognizeButton, pinButton, copyButton, saveButton, undoButton, redoButton] {
            button.imagePosition = .imageOnly
            button.isBordered = false
        }
        recognizeButton.image = EditorToolbarView.icon("scan-text") ?? NSImage(
            systemSymbolName: "text.viewfinder", accessibilityDescription: "Recognize"
        )
        recognizeButton.toolTip = L10n.tr("Recognize text and barcodes", "识别文字与条码")
        pinButton.image = EditorToolbarView.icon("pin") ?? NSImage(
            systemSymbolName: "pin", accessibilityDescription: "Pin"
        )
        pinButton.toolTip = L10n.tr("Pin as floating window (⌘P)", "贴图置顶 (⌘P)")
        copyButton.image = EditorToolbarView.icon("copy")
        copyButton.toolTip = L10n.tr("Copy and close (Enter)", "复制并关闭 (Enter)")
        saveButton.image = EditorToolbarView.icon("save")
        saveButton.toolTip = L10n.tr("Save (⌘S)", "保存 (⌘S)")
        undoButton.image = EditorToolbarView.icon("undo-2")
        undoButton.toolTip = L10n.tr("Undo (⌘Z)", "撤销 (⌘Z)")
        redoButton.image = EditorToolbarView.icon("redo-2")
        redoButton.toolTip = L10n.tr("Redo (⇧⌘Z)", "重做 (⇧⌘Z)")

        colorWell.toolTip = L10n.tr("Annotation color", "标注颜色")
        widthSlider.toolTip = L10n.tr("Stroke width", "线条粗细")
        for label in [sizeLabel, zoomLabel] {
            label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
        }

        let leading = NSStackView(views: [
            copyButton, saveButton, pinButton, Self.separator(), segmented,
        ])
        leading.orientation = .horizontal
        leading.spacing = 6
        leading.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 4)

        let trailing = NSStackView(views: [
            recognizeButton, undoButton, redoButton, Self.separator(),
            colorWell, widthSlider, sizeLabel, zoomLabel,
        ])
        trailing.orientation = .horizontal
        trailing.spacing = 6
        trailing.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 8)

        let leadingVC = NSTitlebarAccessoryViewController()
        leadingVC.view = leading
        leadingVC.layoutAttribute = .leading
        let trailingVC = NSTitlebarAccessoryViewController()
        trailingVC.view = trailing
        trailingVC.layoutAttribute = .trailing
        leadingAccessory = leadingVC
        trailingAccessory = trailingVC

        super.init()

        for control in [segmented, colorWell, widthSlider, recognizeButton, pinButton, copyButton, saveButton, undoButton, redoButton] {
            control.controlSize = .small
        }
        segmented.selectedSegment = 0
        segmented.target = self
        segmented.action = #selector(toolChanged)
        colorWell.target = self
        colorWell.action = #selector(colorChanged)
        widthSlider.target = self
        widthSlider.action = #selector(widthChanged)
        recognizeButton.target = self
        recognizeButton.action = #selector(recognizeAction)
        pinButton.target = self
        pinButton.action = #selector(pinAction)
        copyButton.target = self
        copyButton.action = #selector(copyAction)
        saveButton.target = self
        saveButton.action = #selector(saveAction)
        undoButton.target = self
        undoButton.action = #selector(undo)
        redoButton.target = self
        redoButton.action = #selector(redo)

        widthSlider.widthAnchor.constraint(equalToConstant: 80).isActive = true
    }

    /// Thin vertical separator for the title-bar stacks.
    private static func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return box
    }

    func updateReadouts(size: CGSize, zoom: CGFloat) {
        sizeLabel.stringValue = "\(Int(size.width))×\(Int(size.height)) px"
        zoomLabel.stringValue = "\(Int((zoom * 100).rounded()))%"
    }

    func setRecognizing(_ recognizing: Bool) {
        recognizeButton.isEnabled = !recognizing
    }

    @objc private func toolChanged() {
        let index = segmented.selectedSegment
        guard index >= 0, index < EditorTool.allCases.count else { return }
        onTool(EditorTool.allCases[index])
    }

    @objc private func colorChanged() { onColor(colorWell.color.rgbaValue) }
    @objc private func widthChanged() { onWidth(widthSlider.doubleValue) }
    @objc private func recognizeAction() { onRecognize() }
    @objc private func pinAction() { onPin() }
    @objc private func copyAction() { onCopy() }
    @objc private func saveAction() { onSave() }
    @objc private func undo() { onUndo() }
    @objc private func redo() { onRedo() }
}
