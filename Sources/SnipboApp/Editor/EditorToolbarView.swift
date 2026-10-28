import AppKit
import SnipboCore

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

/// The editor's primary action: an accent-filled tile that stays visible at
/// rest, unlike the quiet icon buttons, so copy-and-close reads as the obvious
/// way out. Hover brightens the fill and a press dims it.
@MainActor
private final class AccentActionButton: HoverButton {
    override var washColor: NSColor { DesignTokens.Color.accent }
    override var hoverAlpha: CGFloat { 1 }
    override var pressedAlpha: CGFloat { 0.7 }
    override var washInset: CGFloat { 0 }
}

/// Shottr-style editor toolbar pinned to the top of a full-size-content
/// window: actions and tools on the left, recognize/undo/redo and the live
/// size/zoom readouts on the right. The style controls live in the floating
/// panel over the canvas. The bar drags the window; the canvas below does not.
@MainActor
final class EditorToolbarView: NSView {
    /// Shottr-style standalone tool buttons, one per `EditorTool`.
    private var toolButtons: [HoverButton] = []
    private let redactButton = NSButton()
    private let recognizeButton = NSButton()
    private let pinButton = NSButton()
    private let copyButton = AccentActionButton(frame: .zero)
    private let saveButton = NSButton()
    private let undoButton = NSButton()
    private let redoButton = NSButton()
    /// The size readout doubles as the resize entry point: clicking the size
    /// that sits just before the zoom percentage opens the image options.
    private let sizeButton = ReadoutPillButton()
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
    private let onRedact: (RedactionMode) -> Void
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
        onRedact: @escaping (RedactionMode) -> Void,
        onRecognize: @escaping () -> Void,
        onPin: @escaping () -> Void,
        onCopy: @escaping () -> Void,
        onSave: @escaping () -> Void,
        onShowOptions: @escaping () -> Void
    ) {
        self.onTool = onTool
        self.onUndo = onUndo
        self.onRedo = onRedo
        self.onRedact = onRedact
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
        let allIcons = EditorTool.allCases.map { EditorToolbarView.icon($0.iconName, size: 16) }
        let iconsUsable = allIcons.allSatisfy { $0 != nil }
        let buttons: [HoverButton] = EditorTool.allCases.enumerated().map { index, tool in
            let button = HoverButton(frame: .zero)
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
            // Icon-only buttons would otherwise be announced as "button".
            button.setAccessibilityLabel(tool.title)
            return button
        }
        let toolsStack = NSStackView(views: buttons)
        toolsStack.orientation = .horizontal
        toolsStack.spacing = DesignTokens.Spacing.icon

        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: Self.height))

        for button in [
            recognizeButton, pinButton, copyButton, saveButton,
            undoButton, redoButton, redactButton,
        ] {
            button.imagePosition = .imageOnly
            button.isBordered = false
        }
        redactButton.image = EditorToolbarView.icon("shield") ?? NSImage(
            systemSymbolName: "shield", accessibilityDescription: "Redact"
        )
        redactButton.toolTip = L10n.tr(
            "Privacy redaction: sensitive text, faces, or all text",
            "隐私打码：敏感文本、人脸或全部文字"
        )
        recognizeButton.image = EditorToolbarView.icon("scan-text") ?? NSImage(
            systemSymbolName: "text.viewfinder", accessibilityDescription: "Recognize"
        )
        recognizeButton.toolTip = L10n.tr("Recognize text and barcodes", "识别文字与条码")
        pinButton.image = EditorToolbarView.icon("pin") ?? NSImage(
            systemSymbolName: "pin", accessibilityDescription: "Pin"
        )
        pinButton.toolTip = L10n.tr("Pin as floating window (⌘P)", "贴图置顶 (⌘P)")
        copyButton.image = EditorToolbarView.icon("copy")
        copyButton.contentTintColor = .white
        copyButton.baseFillAlpha = 0.9
        copyButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        copyButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        copyButton.toolTip = L10n.tr("Copy and close (⌘C / Enter)", "复制并关闭 (⌘C / Enter)")
        copyButton.setAccessibilityLabel(L10n.tr("Copy and close", "复制并关闭"))
        saveButton.image = EditorToolbarView.icon("save")
        saveButton.toolTip = L10n.tr("Save (⌘S)", "保存 (⌘S)")
        undoButton.image = EditorToolbarView.icon("undo-2")
        undoButton.toolTip = L10n.tr("Undo (⌘Z)", "撤销 (⌘Z)")
        redoButton.image = EditorToolbarView.icon("redo-2")
        redoButton.toolTip = L10n.tr("Redo (⇧⌘Z)", "重做 (⇧⌘Z)")

        zoomLabel.font = DesignTokens.readoutFont
        zoomLabel.textColor = DesignTokens.Color.textSecondary
        // Fixed width: the zoom digits change on every pinch tick, and letting
        // the label resize would shift the icons beside it.
        zoomLabel.alignment = .right
        zoomLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true

        sizeButton.attributedTitle = Self.readoutTitle("0×0 px")
        sizeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        sizeButton.heightAnchor.constraint(equalToConstant: 22).isActive = true
        sizeButton.toolTip = L10n.tr(
            "Resize image · logical-point readouts",
            "调整图像大小 · 逻辑点读数"
        )

        for control in [
            recognizeButton, pinButton, copyButton, saveButton,
            undoButton, redoButton, redactButton, sizeButton,
        ] {
            control.controlSize = .small
        }
        toolButtons = buttons
        for button in toolButtons {
            button.target = self
            button.action = #selector(toolButtonPressed(_:))
        }
        toolButtons.first?.showsSelected = true
        redactButton.target = self
        redactButton.action = #selector(showRedactMenu)
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
        sizeButton.target = self
        sizeButton.action = #selector(showOptions)

        let background = MaterialBackgroundView(bottomHairline: true)
        addSubview(background, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Leading: secondary window actions + tools. Trailing: recognize,
        // undo/redo, the size/zoom readouts, and the accent copy-and-close
        // action at the far right edge — the most-used action sits where the
        // pointer already is after a selection. The spacer stretches so the
        // trailing group hugs the right edge at any window width. The leading
        // inset clears the traffic lights, which sit inside this strip since
        // the window is full-size-content (72 ≈ 3 buttons + system padding +
        // breathing room).
        let leading = NSStackView(views: [
            saveButton, pinButton, Self.separator(), toolsStack,
        ])
        leading.orientation = .horizontal
        leading.spacing = DesignTokens.Spacing.tight
        let trailing = NSStackView(views: [
            redactButton, recognizeButton, undoButton, redoButton, Self.separator(),
            sizeButton, zoomLabel, copyButton,
        ])
        trailing.orientation = .horizontal
        trailing.spacing = DesignTokens.Spacing.tight
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
            leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 72),
            leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            spacer.leadingAnchor.constraint(equalTo: leading.trailingAnchor, constant: 10),
            spacer.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -10),
            spacer.centerYAnchor.constraint(equalTo: centerYAnchor),
            spacer.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The transparent title bar leaves no native drag strip, so the toolbar
    /// itself drags the window. Controls inside the bar are hit first and
    /// never get here, and the canvas below keeps handling its own clicks.
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    /// Thin vertical separator for the toolbar groups.
    private static func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return box
    }

    func updateReadouts(size: CGSize, zoom: CGFloat) {
        sizeButton.attributedTitle = Self.readoutTitle("\(Int(size.width))×\(Int(size.height)) px")
        zoomLabel.stringValue = "\(Int((zoom * 100).rounded()))%"
    }

    /// The size readout, as the resize popover's anchor view.
    var optionsAnchor: NSView { sizeButton }

    /// Matches the readout typography while staying clickable.
    private static func readoutTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: DesignTokens.readoutFont,
            .foregroundColor: DesignTokens.Color.textSecondary,
        ])
    }

    @objc private func showOptions() { onShowOptions() }

    func setRecognizing(_ recognizing: Bool) {
        recognizeButton.isEnabled = !recognizing
    }

    func setRedacting(_ redacting: Bool) {
        redactButton.isEnabled = !redacting
    }

    @objc private func showRedactMenu() {
        let menu = NSMenu()
        let items: [(String, RedactionMode)] = [
            (L10n.tr("Redact Sensitive Text", "打码敏感文本"), .sensitiveText),
            (L10n.tr("Redact Faces", "打码人脸"), .faces),
            (L10n.tr("Redact All Text", "打码全部文字"), .allText),
        ]
        for (title, mode) in items {
            let item = NSMenuItem(
                title: title,
                action: #selector(redactItem(_:)),
                keyEquivalent: ""
            )
            item.tag = mode.rawValue
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: redactButton.bounds.height + 4),
            in: redactButton
        )
    }

    @objc private func redactItem(_ sender: NSMenuItem) {
        guard let mode = RedactionMode(rawValue: sender.tag) else { return }
        onRedact(mode)
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

    @objc private func recognizeAction() { onRecognize() }
    @objc private func pinAction() { onPin() }
    @objc private func copyAction() { onCopy() }
    @objc private func saveAction() { onSave() }
    @objc private func undo() { onUndo() }
    @objc private func redo() { onRedo() }
}
