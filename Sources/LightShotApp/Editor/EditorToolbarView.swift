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

/// Shottr-style editor toolbar pinned to the top of a full-size-content
/// window: actions and tools on the left, recognize/undo/redo/color and the
/// live size/zoom readouts on the right. The bar drags the window; the canvas
/// below does not.
@MainActor
final class EditorToolbarView: NSView {
    /// Shottr-style standalone tool buttons, one per `EditorTool`.
    private var toolButtons: [ToolButton] = []
    private let colorWell = NSColorWell()
    private let hexLabel = NSTextField(labelWithString: "#FF0000")
    private let widthSlider = NSSlider(value: 3, minValue: 1, maxValue: 24, target: nil, action: nil)
    private let recognizeButton = NSButton()
    private let pinButton = NSButton()
    private let copyButton = NSButton()
    private let saveButton = NSButton()
    private let undoButton = NSButton()
    private let redoButton = NSButton()
    private let optionsButton = NSButton()
    private let sizeLabel = NSTextField(labelWithString: "0×0 px")
    private let zoomLabel = NSTextField(labelWithString: "100%")

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
    private let onShowOptions: () -> Void

    /// Height of the toolbar strip; the window's content sits below it.
    static let height: CGFloat = 36

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
        onShowOptions: @escaping () -> Void
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
        self.onShowOptions = onShowOptions

        // Shottr-style standalone tool buttons: separate icon buttons that
        // highlight on hover and mark the active tool with a rounded
        // background, instead of a connected segmented control. Falls back to
        // text buttons when Lucide icons are not bundled (harness contexts).
        // Buttons are fully built before `super.init`; target/action, which
        // capture self, are attached afterwards.
        let allIcons = EditorTool.allCases.map { EditorToolbarView.icon($0.iconName, size: 15) }
        let iconsUsable = allIcons.allSatisfy { $0 != nil }
        let buttons: [ToolButton] = EditorTool.allCases.enumerated().map { index, tool in
            let button = ToolButton(frame: .zero)
            button.tag = index
            if iconsUsable, let image = allIcons[index] {
                button.image = image
                button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            } else {
                button.title = tool.title
                button.font = NSFont.systemFont(ofSize: 10, weight: .medium)
            }
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
            button.toolTip = tool.hotKeyLetter.map { "\(tool.title) (\($0.uppercased()))" } ?? tool.title
            return button
        }
        let toolsStack = NSStackView(views: buttons)
        toolsStack.orientation = .horizontal
        toolsStack.spacing = 4

        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: Self.height))

        for button in [recognizeButton, pinButton, copyButton, saveButton, undoButton, redoButton, optionsButton] {
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
        optionsButton.image = EditorToolbarView.icon("scan") ?? NSImage(
            systemSymbolName: "plusminus.viewfinder", accessibilityDescription: "Options"
        )
        optionsButton.toolTip = L10n.tr("Resize image · logical-point readouts", "调整图像大小 · 逻辑点读数")

        colorWell.toolTip = L10n.tr("Annotation color", "标注颜色")
        hexLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        hexLabel.textColor = .secondaryLabelColor
        hexLabel.toolTip = L10n.tr("Press Tab to copy the color", "按 Tab 复制色值")
        widthSlider.toolTip = L10n.tr("Stroke width — affects the selected annotation, or the next one you draw", "线条粗细 — 作用于选中的标注，或接下来绘制的标注")
        widthSlider.isContinuous = true
        for label in [sizeLabel, zoomLabel] {
            label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
        }

        for control in [colorWell, widthSlider, recognizeButton, pinButton, copyButton, saveButton, undoButton, redoButton, optionsButton] {
            control.controlSize = .small
        }
        toolButtons = buttons
        for button in toolButtons {
            button.target = self
            button.action = #selector(toolButtonPressed(_:))
        }
        toolButtons.first?.showsSelected = true
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
        optionsButton.target = self
        optionsButton.action = #selector(showOptions)

        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // Leading: window actions + tools. Trailing: recognize, undo/redo,
        // color, width, and the readouts. The spacer stretches so the trailing
        // group hugs the right edge at any window width.
        let leading = NSStackView(views: [
            copyButton, saveButton, pinButton, Self.separator(), toolsStack,
        ])
        leading.orientation = .horizontal
        leading.spacing = 6
        let trailing = NSStackView(views: [
            recognizeButton, undoButton, redoButton, Self.separator(),
            colorWell, hexLabel, widthSlider, sizeLabel, zoomLabel, optionsButton,
        ])
        trailing.orientation = .horizontal
        trailing.spacing = 6
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        leading.translatesAutoresizingMaskIntoConstraints = false
        trailing.translatesAutoresizingMaskIntoConstraints = false
        spacer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(leading)
        addSubview(trailing)
        addSubview(spacer)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            spacer.leadingAnchor.constraint(equalTo: leading.trailingAnchor, constant: 10),
            spacer.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -10),
            spacer.centerYAnchor.constraint(equalTo: centerYAnchor),
            spacer.heightAnchor.constraint(equalToConstant: 1),
            widthSlider.widthAnchor.constraint(equalToConstant: 80),
            colorWell.widthAnchor.constraint(equalToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Thin vertical separator for the toolbar groups.
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

    /// Mirrors the style being edited (the selected annotation's, or the
    /// default for new annotations) into the color well, hex readout, and
    /// width slider. Programmatic value changes do not fire the control
    /// actions, so this cannot feed back into the controller.
    func syncStyleControls(lineWidth: CGFloat, color: RGBA) {
        widthSlider.doubleValue = lineWidth
        colorWell.color = NSColor(color)
        hexLabel.stringValue = String(
            format: "#%02X%02X%02X",
            Int((color.red * 255).rounded()),
            Int((color.green * 255).rounded()),
            Int((color.blue * 255).rounded())
        )
    }

    /// The options button, as the popover's anchor view.
    var optionsAnchor: NSView { optionsButton }

    @objc private func showOptions() { onShowOptions() }

    func setRecognizing(_ recognizing: Bool) {
        recognizeButton.isEnabled = !recognizing
    }

    /// Marks the active tool's button; called whenever the tool changes from
    /// any path (clicks, single-key shortcuts) so the bar stays in sync.
    func setSelectedTool(_ tool: EditorTool) {
        for (index, button) in toolButtons.enumerated() {
            button.showsSelected = EditorTool.allCases[index] == tool
        }
    }

    @objc private func toolButtonPressed(_ sender: NSButton) {
        let index = sender.tag
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

/// Borderless tool button that paints its own rounded background when hovered
/// or selected — the Shottr toolbar look. The icon stays a template so it
/// follows the appearance.
@MainActor
private final class ToolButton: NSButton {
    var showsSelected = false {
        didSet { needsDisplay = true }
    }
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        imagePosition = .imageOnly
        setButtonType(.momentaryChange)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if showsSelected || isHovered {
            NSColor.labelColor.withAlphaComponent(showsSelected ? 0.16 : 0.09).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}
