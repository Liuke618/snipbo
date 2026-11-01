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

/// The editor's primary action: an accent-filled circle that stays visible at
/// rest, unlike the quiet icon buttons, so copy-and-close reads as the obvious
/// way out. Hover brightens the fill and a press dims it.
@MainActor
private final class AccentActionButton: HoverButton {
    override var washColor: NSColor { DesignTokens.Color.accent }
    override var hoverAlpha: CGFloat { 1 }
    override var pressedAlpha: CGFloat { 0.7 }
    override var washInset: CGFloat { 0 }
    override var washRadius: CGFloat { bounds.height / 2 }
}

/// A floating capsule plate behind one group of chrome controls: raised fill,
/// hairline stroke, drop shadow — the pill that carries a cluster of editor
/// tools over the canvas. The stack hugs the capsule's width.
@MainActor
private final class ChromePill: NSView {
    static let height: CGFloat = 40

    let stack: NSStackView

    /// `groups` are joined by thin separators with generous side gaps, the way
    /// Freeform separates the clusters inside its insert pill; plain `views`
    /// build one continuous row.
    convenience init(
        groups: [[NSView]],
        spacing: CGFloat = 2,
        padding: CGFloat = 8
    ) {
        self.init(views: [], spacing: spacing, padding: padding)
        for group in groups { appendGroup(group) }
    }

    /// Appends one cluster; when the pill already holds views, a separator
    /// with generous side gaps goes in front of it.
    func appendGroup(_ group: [NSView]) {
        if !stack.arrangedSubviews.isEmpty {
            stack.addArrangedSubview(Self.separator())
            let separatorIndex = stack.arrangedSubviews.count - 1
            stack.setCustomSpacing(7, after: stack.arrangedSubviews[separatorIndex - 1])
            stack.setCustomSpacing(7, after: stack.arrangedSubviews[separatorIndex])
        }
        group.forEach(stack.addArrangedSubview)
    }

    init(views: [NSView], spacing: CGFloat = 2, padding: CGFloat = 8) {
        self.stack = NSStackView(views: views)
        let plate = MaterialBackgroundView(
            cornerRadius: Self.height / 2,
            fill: DesignTokens.Color.raised,
            stroke: true
        )
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = DesignTokens.Shadow.panelOpacity
        layer?.shadowRadius = DesignTokens.Shadow.panelRadius
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        // The stack hugs its content; without this the edge pins to the plate
        // let gravityAreas spread the controls across a wider pill.
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        plate.translatesAutoresizingMaskIntoConstraints = false
        addSubview(plate)
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            plate.leadingAnchor.constraint(equalTo: leadingAnchor),
            plate.trailingAnchor.constraint(equalTo: trailingAnchor),
            plate.topAnchor.constraint(equalTo: topAnchor),
            plate.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Thin vertical separator between pill groups. The explicit width is
    /// load-bearing: an `NSBox` separator has no intrinsic width, and leaving
    /// it ambiguous lets the solver stretch the whole pill.
    static func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        box.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return box
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: Self.height / 2,
            cornerHeight: Self.height / 2,
            transform: nil
        )
    }
}

/// Freeform-style floating editor chrome over the canvas. The top row carries
/// three capsule clusters — window actions (save, pin), the annotation tools,
/// and privacy/undo/redo — plus the accent copy-and-close circle at the right
/// edge; the bottom row carries a zoom capsule (− % + | fit) on the left and
/// the size readout that opens resize on the right. The view covers the whole
/// window and is transparent between the two bands, so the canvas receives
/// clicks there; inside a band the gaps between pills drag the window, like a
/// hidden title bar.
@MainActor
final class EditorChromeView: NSView {
    /// Height of the top floating row: a 40pt pill with 4pt breathing.
    static let topBandHeight: CGFloat = 48
    /// Height of the bottom floating row: a 40pt pill with 12pt above the edge.
    static let bottomBandHeight: CGFloat = 52
    /// Vertical chrome the fitted image should clear: both floating rows.
    static let verticalChrome: CGFloat = topBandHeight + bottomBandHeight

    private var toolButtons: [HoverButton] = []
    private let redactButton = HoverButton(frame: .zero)
    private let recognizeButton = HoverButton(frame: .zero)
    private let pinButton = HoverButton(frame: .zero)
    private let saveButton = HoverButton(frame: .zero)
    private let undoButton = HoverButton(frame: .zero)
    private let redoButton = HoverButton(frame: .zero)
    private let copyButton = AccentActionButton(frame: .zero)
    private let zoomOutButton = HoverButton(frame: .zero)
    private let zoomInButton = HoverButton(frame: .zero)
    private let fitButton = HoverButton(frame: .zero)
    /// The size readout doubles as the resize entry point: clicking the size
    /// pill opens the image options.
    private let sizeButton = ReadoutPillButton()
    private let zoomLabel = NSTextField(labelWithString: "100%")

    // The five capsule clusters, kept for the width floors below.
    private let leftPill = ChromePill(views: [])
    private let toolsPill = ChromePill(groups: [])
    private let rightPill = ChromePill(groups: [])
    private let zoomPill = ChromePill(groups: [])
    private let sizePill = ChromePill(views: [])

    /// Scroll and pinch gestures that land on a chrome band are forwarded to
    /// the canvas so zooming never dead-ends under the pills.
    weak var scrollForwardTarget: NSView?

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
    private let onZoomIn: () -> Void
    private let onZoomOut: () -> Void
    private let onFit: () -> Void

    /// Fixed side of the square icon buttons inside the pills.
    private static let buttonSide: CGFloat = 28

    init(
        onTool: @escaping (EditorTool) -> Void,
        onUndo: @escaping () -> Void,
        onRedo: @escaping () -> Void,
        onRedact: @escaping (RedactionMode) -> Void,
        onRecognize: @escaping () -> Void,
        onPin: @escaping () -> Void,
        onCopy: @escaping () -> Void,
        onSave: @escaping () -> Void,
        onShowOptions: @escaping () -> Void,
        onZoomIn: @escaping () -> Void,
        onZoomOut: @escaping () -> Void,
        onFit: @escaping () -> Void
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
        self.onZoomIn = onZoomIn
        self.onZoomOut = onZoomOut
        self.onFit = onFit
        super.init(frame: .zero)

        // Standalone tool buttons: separate icon buttons that highlight on
        // hover and mark the active tool with a rounded background. Falls back
        // to text buttons when Lucide icons are not bundled (harness contexts).
        // Buttons are fully built before `super.init`; target/action, which
        // capture self, are attached afterwards.
        let allIcons = EditorTool.allCases.map { EditorChromeView.icon($0.iconName, size: 16) }
        let iconsUsable = allIcons.allSatisfy { $0 != nil }
        let buttons: [HoverButton] = EditorTool.allCases.enumerated().map { index, tool in
            let button = HoverButton(frame: .zero)
            button.tag = index
            button.heightAnchor.constraint(equalToConstant: Self.buttonSide).isActive = true
            if iconsUsable, let image = allIcons[index] {
                button.image = image
                button.widthAnchor.constraint(equalToConstant: Self.buttonSide).isActive = true
            } else {
                button.title = tool.title
                button.font = NSFont.systemFont(ofSize: 10, weight: .medium)
            }
            button.toolTip = tool.hotKeyLetter.map { "\(tool.title) (\($0.uppercased()))" } ?? tool.title
            // Icon-only buttons would otherwise be announced as "button".
            button.setAccessibilityLabel(tool.title)
            return button
        }
        let toolsStack = NSStackView(views: buttons)
        toolsStack.orientation = .horizontal
        toolsStack.spacing = DesignTokens.Spacing.icon

        for button in [
            recognizeButton, pinButton, saveButton,
            undoButton, redoButton, redactButton,
            zoomOutButton, zoomInButton, fitButton,
        ] {
            button.imagePosition = .imageOnly
            button.washRadiusOverride = DesignTokens.Radius.card
            button.widthAnchor.constraint(equalToConstant: Self.buttonSide).isActive = true
            button.heightAnchor.constraint(equalToConstant: Self.buttonSide).isActive = true
        }
        redactButton.image = EditorChromeView.icon("shield") ?? NSImage(
            systemSymbolName: "shield", accessibilityDescription: "Redact"
        )
        redactButton.toolTip = L10n.tr(
            "Privacy redaction: sensitive text, faces, or all text",
            "隐私打码：敏感文本、人脸或全部文字"
        )
        redactButton.setAccessibilityLabel(L10n.tr("Privacy redaction", "隐私打码"))
        recognizeButton.image = EditorChromeView.icon("scan-text") ?? NSImage(
            systemSymbolName: "text.viewfinder", accessibilityDescription: "Recognize"
        )
        recognizeButton.toolTip = L10n.tr("Recognize text and barcodes", "识别文字与条码")
        recognizeButton.setAccessibilityLabel(L10n.tr("Recognize", "识别"))
        pinButton.image = EditorChromeView.icon("pin") ?? NSImage(
            systemSymbolName: "pin", accessibilityDescription: "Pin"
        )
        pinButton.toolTip = L10n.tr("Pin as floating window (⌘P)", "贴图置顶 (⌘P)")
        pinButton.setAccessibilityLabel(L10n.tr("Pin as floating window", "贴图置顶"))
        saveButton.image = EditorChromeView.icon("save")
        saveButton.toolTip = L10n.tr("Save (⌘S)", "保存 (⌘S)")
        saveButton.setAccessibilityLabel(L10n.tr("Save", "保存"))
        undoButton.image = EditorChromeView.icon("undo-2")
        undoButton.toolTip = L10n.tr("Undo (⌘Z)", "撤销 (⌘Z)")
        undoButton.setAccessibilityLabel(L10n.tr("Undo", "撤销"))
        redoButton.image = EditorChromeView.icon("redo-2")
        redoButton.toolTip = L10n.tr("Redo (⇧⌘Z)", "重做 (⇧⌘Z)")
        redoButton.setAccessibilityLabel(L10n.tr("Redo", "重做"))

        copyButton.image = EditorChromeView.icon("copy")
        copyButton.contentTintColor = .white
        copyButton.baseFillAlpha = 0.9
        copyButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        copyButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        copyButton.toolTip = L10n.tr("Copy and close (⌘C / Enter)", "复制并关闭 (⌘C / Enter)")
        copyButton.setAccessibilityLabel(L10n.tr("Copy and close", "复制并关闭"))

        let zoomIconsUsable = [
            EditorChromeView.icon("minus"),
            EditorChromeView.icon("plus"),
            EditorChromeView.icon("scan"),
        ]
        if let image = zoomIconsUsable[0] {
            zoomOutButton.image = image
        } else {
            zoomOutButton.title = "−"
            zoomOutButton.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        }
        zoomOutButton.toolTip = L10n.tr("Zoom out", "缩小")
        zoomOutButton.setAccessibilityLabel(L10n.tr("Zoom out", "缩小"))
        if let image = zoomIconsUsable[1] {
            zoomInButton.image = image
        } else {
            zoomInButton.title = "+"
            zoomInButton.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        }
        zoomInButton.toolTip = L10n.tr("Zoom in", "放大")
        zoomInButton.setAccessibilityLabel(L10n.tr("Zoom in", "放大"))
        if let image = zoomIconsUsable[2] {
            fitButton.image = image
        } else {
            fitButton.title = L10n.tr("Fit", "适应")
            fitButton.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        }
        fitButton.toolTip = L10n.tr("Fit to window", "适应窗口")
        fitButton.setAccessibilityLabel(L10n.tr("Fit to window", "适应窗口"))

        zoomLabel.font = DesignTokens.readoutFont
        zoomLabel.textColor = DesignTokens.Color.textSecondary
        // Fixed width: the zoom digits change on every pinch tick, and letting
        // the label resize would shift the icons beside it.
        zoomLabel.alignment = .center
        zoomLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

        sizeButton.attributedTitle = Self.readoutTitle("0×0 px")
        sizeButton.baseFillAlpha = nil
        sizeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        sizeButton.heightAnchor.constraint(equalToConstant: Self.buttonSide).isActive = true
        sizeButton.toolTip = L10n.tr(
            "Resize image · logical-point readouts",
            "调整图像大小 · 逻辑点读数"
        )

        for control in [
            recognizeButton, pinButton, saveButton, undoButton, redoButton,
            redactButton, zoomOutButton, zoomInButton, fitButton, sizeButton,
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
        saveButton.target = self
        saveButton.action = #selector(saveAction)
        undoButton.target = self
        undoButton.action = #selector(undo)
        redoButton.target = self
        redoButton.action = #selector(redo)
        copyButton.target = self
        copyButton.action = #selector(copyAction)
        zoomOutButton.target = self
        zoomOutButton.action = #selector(zoomOutAction)
        zoomInButton.target = self
        zoomInButton.action = #selector(zoomInAction)
        fitButton.target = self
        fitButton.action = #selector(fitAction)
        sizeButton.target = self
        sizeButton.action = #selector(showOptions)

        // Top row: window actions, tools, privacy/undo/redo, copy. The tool
        // pill centers in the window; on a too-narrow window it slides aside
        // before it may overlap the trailing cluster (never unsatisfiable).
        leftPill.stack.addArrangedSubview(saveButton)
        leftPill.stack.addArrangedSubview(pinButton)
        let toolGroups: [[NSView]] = [
            [buttons[0]],
            Array(buttons[1...6]),
            Array(buttons[7...9]),
            Array(buttons[10...15]),
            [buttons[16]],
        ]
        for group in toolGroups { toolsPill.appendGroup(group) }
        rightPill.appendGroup([redactButton, recognizeButton])
        rightPill.appendGroup([undoButton, redoButton])

        // Bottom row: zoom stepper + fit on the left, the size readout on the
        // right — the two utility corners.
        zoomPill.appendGroup([zoomOutButton, zoomLabel, zoomInButton])
        zoomPill.appendGroup([fitButton])
        sizePill.stack.addArrangedSubview(sizeButton)

        for pill in [leftPill, toolsPill, rightPill, zoomPill, sizePill] {
            pill.translatesAutoresizingMaskIntoConstraints = false
            addSubview(pill)
        }
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(copyButton)

        // Narrow-window degradation, in break order: the tool pill first gives
        // up its centered position, then may rest against the left cluster —
        // the right cluster and the copy circle never move. All three sit
        // below the window-sizing threshold (500): AppKit auto-grows a window
        // to satisfy higher-priority constraints, and the tool pill must never
        // dictate the window's width.
        let toolsCenterX = toolsPill.centerXAnchor.constraint(equalTo: centerXAnchor)
        toolsCenterX.priority = NSLayoutConstraint.Priority(498)
        let toolsAfterLeft = toolsPill.leadingAnchor.constraint(
            greaterThanOrEqualTo: leftPill.trailingAnchor, constant: 16
        )
        toolsAfterLeft.priority = NSLayoutConstraint.Priority(497)
        let toolsBelowRight = toolsPill.trailingAnchor.constraint(
            lessThanOrEqualTo: rightPill.leadingAnchor, constant: -16
        )
        toolsBelowRight.priority = NSLayoutConstraint.Priority(499)
        // Vertical centering has no competing constraint, but it also stays
        // below the window-sizing threshold.
        let toolsCenterY = toolsPill.centerYAnchor.constraint(
            equalTo: topAnchor, constant: Self.topBandHeight / 2
        )
        toolsCenterY.priority = NSLayoutConstraint.Priority(499)
        NSLayoutConstraint.activate([
            leftPill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 76),
            leftPill.centerYAnchor.constraint(
                equalTo: topAnchor, constant: Self.topBandHeight / 2
            ),
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            copyButton.centerYAnchor.constraint(
                equalTo: topAnchor, constant: Self.topBandHeight / 2
            ),
            rightPill.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -10),
            rightPill.centerYAnchor.constraint(
                equalTo: topAnchor, constant: Self.topBandHeight / 2
            ),
            toolsAfterLeft,
            toolsCenterX,
            toolsCenterY,
            toolsBelowRight,
            zoomPill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            zoomPill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            sizePill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            sizePill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Band hit-testing and gestures

    /// The honest width floor for the window: the top pill row without any
    /// overlap, or the two bottom utility pills without losing their corner
    /// gaps. Unlike `fittingSize` — whose soft centering constraints degrade
    /// below the full row — this is what `sizeWindowToFitImage` respects when
    /// sizing the window, so every pill stays reachable at open.
    var floorWidth: CGFloat {
        let topRow = 76 + leftPill.fittingSize.width + 16
            + toolsPill.fittingSize.width + 16
            + rightPill.fittingSize.width + 10 + 40 + 12
        let bottomRow = 16 + zoomPill.fittingSize.width + 16
            + sizePill.fittingSize.width + 16
        return max(topRow, bottomRow)
    }

    override var isFlipped: Bool { true }

    /// The overlay itself is invisible: only the two chrome bands own clicks
    /// (they drag the window between the pills), everywhere else the hit falls
    /// through to the canvas below. Controls inside the pills are hit first
    /// through `super.hitTest` and never get here.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        guard let hit = super.hitTest(point) else { return nil }
        guard hit === self else { return hit }
        let local = convert(point, from: superview)
        let inTopBand = local.y >= 0 && local.y <= Self.topBandHeight
        let inBottomBand = local.y >= bounds.height - Self.bottomBandHeight
        return inTopBand || inBottomBand ? self : nil
    }

    /// The transparent title bar leaves no native drag strip, so the chrome
    /// bands drag the window between the pills.
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if let target = scrollForwardTarget {
            target.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func magnify(with event: NSEvent) {
        if let target = scrollForwardTarget {
            target.magnify(with: event)
        } else {
            super.magnify(with: event)
        }
    }

    // MARK: Readouts and state

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
    @objc private func zoomInAction() { onZoomIn() }
    @objc private func zoomOutAction() { onZoomOut() }
    @objc private func fitAction() { onFit() }
}
