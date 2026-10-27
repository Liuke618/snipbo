import AppKit
import SnipboCore

/// Floating annotation-style controls pinned to the top-right of the canvas.
/// Shape tools see color, hex, and stroke width; the text tool swaps the
/// stroke slider for font controls and adds a text-only row. The panel floats
/// over the canvas, so growing it never reflows the editor.
@MainActor
final class EditorStylePanelView: NSView {
    private let effect = NSVisualEffectView()
    private let colorWell = NSColorWell()
    private let hexLabel = NSTextField(labelWithString: "#FF0000")
    private let widthSlider = NSSlider(value: 3, minValue: 1, maxValue: 24, target: nil, action: nil)
    private let sizeField = SizeTextField(string: "3")
    private let sizeUnitLabel = NSTextField(labelWithString: "px")
    private let sizeWell = NSView()
    private let fontSizeSlider = NSSlider(value: 24, minValue: 10, maxValue: 96, target: nil, action: nil)
    private let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let boldButton = NSButton(title: "B", target: nil, action: nil)
    private let alignmentControl = NSSegmentedControl(
        images: [
            NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil),
            NSImage(systemSymbolName: "text.aligncenter", accessibilityDescription: nil),
            NSImage(systemSymbolName: "text.alignright", accessibilityDescription: nil),
        ].compactMap { $0 },
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let backgroundButton = NSButton(
        checkboxWithTitle: "",
        target: nil,
        action: nil
    )
    private let lineStyleControl = NSSegmentedControl(
        images: [
            EditorStylePanelView.lineStyleIcon(dashed: false),
            EditorStylePanelView.lineStyleIcon(dashed: true),
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let fillButton = NSButton(
        checkboxWithTitle: "",
        target: nil,
        action: nil
    )
    private let arrowButton = NSButton()
    private let textRow = NSStackView()
    private let shapeRow = NSStackView()
    private let paletteRow = NSStackView()
    private let onColor: (RGBA) -> Void
    private let onWidth: (CGFloat) -> Void
    private let onFontSize: (CGFloat) -> Void
    private let onFontName: (String?) -> Void
    private let onBold: (Bool) -> Void
    private let onAlignment: (AnnotationTextAlignment) -> Void
    private let onTextBackground: (Bool) -> Void
    private let onLineStyle: (AnnotationLineStyle) -> Void
    private let onFill: (Bool) -> Void
    private let onArrowStyle: (AnnotationArrowStyle) -> Void
    /// Reports how far the user dragged the panel's background, in window
    /// points; the owner clamps and applies it.
    var onMove: ((CGSize) -> Void)?
    /// Called after Return commits a typed size, so focus can go back to the
    /// canvas and tool shortcuts keep working.
    var onFinishEditing: (() -> Void)?
    private var dragOrigin: NSPoint?
    private var swatches: [ColorSwatchButton] = []
    /// Whether the shared size readout currently edits the text size.
    private var showsTextSize = false

    private static let paletteColors: [RGBA] = [
        RGBA(red: 0.93, green: 0.16, blue: 0.16),
        RGBA(red: 1.00, green: 0.58, blue: 0.00),
        RGBA(red: 1.00, green: 0.80, blue: 0.00),
        RGBA(red: 0.13, green: 0.65, blue: 0.29),
        RGBA(red: 0.10, green: 0.45, blue: 0.90),
        RGBA(red: 0.55, green: 0.25, blue: 0.85),
        .black,
        .white,
    ]

    /// nil represents the system UI font.
    private static let fontChoices: [(title: String, name: String?)] = [
        (L10n.tr("System", "系统"), nil),
        ("Helvetica", "Helvetica"),
        ("Avenir Next", "AvenirNext-Regular"),
        ("PingFang SC", "PingFangSC-Regular"),
        ("Menlo", "Menlo-Regular"),
        ("Georgia", "Georgia"),
    ]

    /// Slider values are whole points most of the time; keep one decimal only
    /// when the user lands between two.
    private static func widthText(_ value: CGFloat) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded)
    }

    /// Background clicks move the panel; clicks on inputs keep going to them.
    /// The bounds check is what keeps the panel from claiming clicks that
    /// belong to the canvas or toolbar behind it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        let hit = super.hitTest(point)
        if let field = hit as? NSTextField, field.isEditable { return hit }
        switch hit {
        case is NSButton, is NSSlider, is NSSegmentedControl, is NSColorWell:
            return hit
        default:
            return self
        }
    }

    /// Commits a typed size when focus leaves the field.
    @objc private func sizeFieldEditingEnded(_ note: Notification) {
        sizeWell.layer?.backgroundColor = Self.wellFill(forFocus: false).cgColor
        commitTypedSize()
    }

    private static func wellFill(forFocus focused: Bool) -> NSColor {
        focused
            ? NSColor.controlAccentColor.withAlphaComponent(0.3)
            : NSColor.labelColor.withAlphaComponent(0.07)
    }

    @objc private func sizeFieldCommitted() {
        commitTypedSize()
        onFinishEditing?()
    }

    private func commitTypedSize() {
        let text = sizeField.stringValue
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        let current = showsTextSize ? fontSizeSlider.doubleValue : widthSlider.doubleValue
        guard let typed = Double(text) else {
            sizeField.stringValue = Self.widthText(current)
            return
        }
        if showsTextSize {
            let size = min(max(typed, fontSizeSlider.minValue), fontSizeSlider.maxValue)
            onFontSize(size)
            sizeField.stringValue = Self.widthText(size)
        } else {
            let width = min(max(typed, widthSlider.minValue), widthSlider.maxValue)
            onWidth(width)
            sizeField.stringValue = Self.widthText(width)
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let current = event.locationInWindow
        onMove?(CGSize(width: current.x - origin.x, height: current.y - origin.y))
        dragOrigin = current
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
    }

    private static func lineStyleIcon(dashed: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            NSColor.black.setStroke()
            let path = NSBezierPath()
            if dashed {
                for start in stride(from: CGFloat(1), to: 15, by: 5) {
                    path.move(to: CGPoint(x: start, y: 8))
                    path.line(to: CGPoint(x: start + 3, y: 8))
                }
            } else {
                path.move(to: CGPoint(x: 1, y: 8))
                path.line(to: CGPoint(x: 15, y: 8))
            }
            path.lineWidth = 1.8
            path.lineCapStyle = .round
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Two hand-drawn 16 pt template images, so the arrow-head control shows
    /// the shape it changes instead of naming it.
    private static func arrowIcon(filled: Bool, chevron: Bool = false) -> NSImage {
        let size = NSSize(width: chevron ? 26 : 16, height: 16)
        let image = NSImage(size: size, flipped: true) { _ in
            let tail = CGPoint(x: 2.5, y: 13.5)
            let tip = CGPoint(x: 13.5, y: 2.5)
            let length = hypot(tip.x - tail.x, tip.y - tail.y)
            let dx = (tip.x - tail.x) / length
            let dy = (tip.y - tail.y) / length
            let normalX = -dy
            let normalY = dx
            func point(at distance: CGFloat, offset: CGFloat) -> CGPoint {
                CGPoint(
                    x: tip.x - dx * distance + normalX * offset,
                    y: tip.y - dy * distance + normalY * offset
                )
            }

            NSColor.black.set()
            if filled {
                let shaft = NSBezierPath()
                shaft.move(to: tail)
                shaft.line(to: point(at: 4, offset: 0))
                shaft.lineWidth = 2.2
                shaft.lineCapStyle = .round
                shaft.stroke()

                let head = NSBezierPath()
                head.move(to: tip)
                head.line(to: point(at: 6.5, offset: 3.2))
                head.line(to: point(at: 6.5, offset: -3.2))
                head.close()
                head.fill()
            } else {
                let path = NSBezierPath()
                path.move(to: tail)
                path.line(to: tip)
                path.move(to: tip)
                path.line(to: point(at: 5.2, offset: 3.4))
                path.move(to: tip)
                path.line(to: point(at: 5.2, offset: -3.4))
                path.lineWidth = 1.6
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }
            if chevron {
                let marker = NSBezierPath()
                marker.move(to: CGPoint(x: 19.5, y: 6.5))
                marker.line(to: CGPoint(x: 22, y: 9))
                marker.line(to: CGPoint(x: 24.5, y: 6.5))
                marker.lineWidth = 1.4
                marker.lineCapStyle = .round
                marker.lineJoinStyle = .round
                marker.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    init(
        onColor: @escaping (RGBA) -> Void,
        onWidth: @escaping (CGFloat) -> Void,
        onFontSize: @escaping (CGFloat) -> Void,
        onFontName: @escaping (String?) -> Void,
        onBold: @escaping (Bool) -> Void,
        onAlignment: @escaping (AnnotationTextAlignment) -> Void,
        onTextBackground: @escaping (Bool) -> Void,
        onLineStyle: @escaping (AnnotationLineStyle) -> Void,
        onFill: @escaping (Bool) -> Void,
        onArrowStyle: @escaping (AnnotationArrowStyle) -> Void
    ) {
        self.onColor = onColor
        self.onWidth = onWidth
        self.onFontSize = onFontSize
        self.onFontName = onFontName
        self.onBold = onBold
        self.onAlignment = onAlignment
        self.onTextBackground = onTextBackground
        self.onLineStyle = onLineStyle
        self.onFill = onFill
        self.onArrowStyle = onArrowStyle
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 40))

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = DesignTokens.Shadow.panelOpacity
        layer?.shadowRadius = DesignTokens.Shadow.panelRadius
        layer?.shadowOffset = CGSize(width: 0, height: -2)

        effect.material = .popover
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = DesignTokens.Radius.panel
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        colorWell.toolTip = L10n.tr("Annotation color", "标注颜色")
        colorWell.colorWellStyle = .minimal
        colorWell.controlSize = .small
        hexLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        hexLabel.textColor = .secondaryLabelColor
        hexLabel.toolTip = L10n.tr("Press Tab to copy the color", "按 Tab 复制色值")
        sizeField.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        sizeField.textColor = .secondaryLabelColor
        sizeField.alignment = .right
        sizeField.isBordered = false
        sizeField.drawsBackground = false
        sizeField.isEditable = true
        sizeField.focusRingType = .none
        sizeField.onBeginEditing = { [weak self] in
            self?.sizeWell.layer?.backgroundColor = Self.wellFill(forFocus: true).cgColor
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sizeFieldEditingEnded(_:)),
            name: NSControl.textDidEndEditingNotification,
            object: sizeField
        )
        sizeField.target = self
        sizeField.action = #selector(sizeFieldCommitted)
        sizeField.toolTip = L10n.tr("Type a size, or drag the slider", "可直接输入数值，或拖动滑杆")
        sizeUnitLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeUnitLabel.textColor = .tertiaryLabelColor
        sizeUnitLabel.toolTip = L10n.tr("Pixels", "像素")
        // One rounded well holds the number and its unit, so the readout reads
        // as a single editable control rather than a field plus loose text.
        sizeWell.wantsLayer = true
        sizeWell.layer?.cornerRadius = DesignTokens.Radius.control
        sizeWell.layer?.backgroundColor = Self.wellFill(forFocus: false).cgColor
        widthSlider.toolTip = L10n.tr(
            "Stroke width — affects the selected annotation, or the next one you draw",
            "线条粗细 — 作用于选中的标注，或接下来绘制的标注"
        )
        widthSlider.isContinuous = true
        widthSlider.controlSize = .small

        fontSizeSlider.toolTip = L10n.tr("Text size", "文字大小")
        fontSizeSlider.isContinuous = true
        fontSizeSlider.controlSize = .small

        for choice in Self.fontChoices {
            fontPopup.addItem(withTitle: choice.title)
            fontPopup.lastItem?.representedObject = choice.name
        }
        fontPopup.controlSize = .small
        fontPopup.toolTip = L10n.tr("Font", "字体")

        boldButton.setButtonType(.toggle)
        boldButton.bezelStyle = .rounded
        boldButton.controlSize = .small
        boldButton.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        boldButton.toolTip = L10n.tr("Bold", "粗体")

        alignmentControl.controlSize = .small
        alignmentControl.selectedSegment = 0
        alignmentControl.toolTip = L10n.tr("Text alignment", "文字对齐")

        backgroundButton.title = L10n.tr("Background", "背景")
        backgroundButton.controlSize = .small
        backgroundButton.toolTip = L10n.tr("Text background", "文字背景")

        lineStyleControl.setToolTip(L10n.tr("Solid line", "实线"), forSegment: 0)
        lineStyleControl.setToolTip(L10n.tr("Dashed line", "虚线"), forSegment: 1)
        lineStyleControl.controlSize = .small
        lineStyleControl.selectedSegment = 0
        lineStyleControl.toolTip = L10n.tr("Line style", "线条样式")

        fillButton.title = L10n.tr("Fill", "填充")
        fillButton.controlSize = .small
        fillButton.toolTip = L10n.tr("Fill shape", "填充形状")

        arrowButton.isBordered = false
        arrowButton.imagePosition = .imageOnly
        arrowButton.image = Self.arrowIcon(filled: true, chevron: true)
        arrowButton.controlSize = .small
        arrowButton.toolTip = L10n.tr("Arrow head", "箭头样式")

        // The panel is a floating tool window: focus rings on its controls read
        // as heavy blue boxes against the dark popover material.
        for control in [
            colorWell, widthSlider, fontSizeSlider, fontPopup, boldButton,
            alignmentControl, backgroundButton, lineStyleControl, fillButton, arrowButton,
        ] as [NSView] {
            (control as? NSControl)?.focusRingType = .none
        }

        colorWell.target = self
        colorWell.action = #selector(colorChanged)
        widthSlider.target = self
        widthSlider.action = #selector(widthChanged)
        fontSizeSlider.target = self
        fontSizeSlider.action = #selector(fontSizeChanged)
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged)
        boldButton.target = self
        boldButton.action = #selector(boldChanged)
        alignmentControl.target = self
        alignmentControl.action = #selector(alignmentChanged)
        backgroundButton.target = self
        backgroundButton.action = #selector(backgroundChanged)
        lineStyleControl.target = self
        lineStyleControl.action = #selector(lineStyleChanged)
        fillButton.target = self
        fillButton.action = #selector(fillChanged)
        arrowButton.target = self
        arrowButton.action = #selector(showArrowMenu)

        let sizeReadout = NSStackView(views: [sizeField, sizeUnitLabel])
        sizeReadout.orientation = .horizontal
        sizeReadout.alignment = .centerY
        sizeReadout.spacing = 2
        sizeReadout.translatesAutoresizingMaskIntoConstraints = false
        sizeWell.addSubview(sizeReadout)

        let topRow = Self.row([colorWell, hexLabel, widthSlider, fontSizeSlider, sizeWell])

        textRow.orientation = .horizontal
        textRow.alignment = .centerY
        textRow.spacing = 8
        textRow.addArrangedSubview(fontPopup)
        textRow.addArrangedSubview(boldButton)
        textRow.addArrangedSubview(alignmentControl)
        textRow.addArrangedSubview(backgroundButton)
        textRow.addArrangedSubview(Self.spacer())
        textRow.isHidden = true
        fontSizeSlider.isHidden = true

        shapeRow.orientation = .horizontal
        shapeRow.alignment = .centerY
        shapeRow.spacing = 8
        shapeRow.addArrangedSubview(lineStyleControl)
        shapeRow.addArrangedSubview(fillButton)
        shapeRow.addArrangedSubview(arrowButton)
        shapeRow.addArrangedSubview(Self.spacer())
        shapeRow.isHidden = true

        paletteRow.orientation = .horizontal
        paletteRow.alignment = .centerY
        paletteRow.spacing = 6
        for (index, color) in Self.paletteColors.enumerated() {
            let swatch = ColorSwatchButton(color: color)
            swatch.tag = index
            swatch.target = self
            swatch.action = #selector(paletteChanged(_:))
            swatch.toolTip = String(
                format: "#%02X%02X%02X",
                Int((color.red * 255).rounded()),
                Int((color.green * 255).rounded()),
                Int((color.blue * 255).rounded())
            )
            swatch.widthAnchor.constraint(equalToConstant: 18).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: 18).isActive = true
            paletteRow.addArrangedSubview(swatch)
            swatches.append(swatch)
        }

        let stack = NSStackView(views: [topRow, shapeRow, textRow, paletteRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DesignTokens.Spacing.tight
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)

        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -12),
            colorWell.widthAnchor.constraint(equalToConstant: 40),
            colorWell.heightAnchor.constraint(equalToConstant: 24),
            hexLabel.widthAnchor.constraint(equalToConstant: 54),
            widthSlider.widthAnchor.constraint(equalToConstant: 100),
            // Wide enough for "23.5" and the three-digit text sizes.
            sizeField.widthAnchor.constraint(equalToConstant: 34),
            sizeField.heightAnchor.constraint(equalToConstant: 16),
            sizeWell.heightAnchor.constraint(equalToConstant: 22),
            sizeReadout.leadingAnchor.constraint(equalTo: sizeWell.leadingAnchor, constant: 7),
            sizeReadout.trailingAnchor.constraint(equalTo: sizeWell.trailingAnchor, constant: -7),
            sizeReadout.centerYAnchor.constraint(equalTo: sizeWell.centerYAnchor),
            fontSizeSlider.widthAnchor.constraint(equalToConstant: 100),
            fontPopup.widthAnchor.constraint(equalToConstant: 118),
            boldButton.widthAnchor.constraint(equalToConstant: 32),
            alignmentControl.widthAnchor.constraint(equalToConstant: 92),
            lineStyleControl.widthAnchor.constraint(equalToConstant: 62),
            arrowButton.widthAnchor.constraint(equalToConstant: 30),
            arrowButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    /// Absorbs the width the widest row adds, so the other rows stay
    /// left-aligned instead of spreading their controls apart.
    private static func spacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return spacer
    }

    private static func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.addArrangedSubview(spacer())
        return row
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: 10,
            cornerHeight: 10,
            transform: nil
        )
    }

    /// Mirrors the style being edited (the selected annotation's, or the
    /// default for new annotations). Programmatic value changes do not fire
    /// the control actions, so this cannot feed back into the controller.
    func syncStyleControls(
        style: AnnotationStyle,
        isText: Bool,
        showsShapeOptions: Bool,
        showsArrowStyle: Bool
    ) {
        widthSlider.doubleValue = style.lineWidth
        fontSizeSlider.doubleValue = style.fontSize
        showsTextSize = isText
        if sizeField.currentEditor() == nil {
            sizeField.stringValue = Self.widthText(isText ? style.fontSize : style.lineWidth)
        }
        colorWell.color = NSColor(style.color)
        hexLabel.stringValue = String(
            format: "#%02X%02X%02X",
            Int((style.color.red * 255).rounded()),
            Int((style.color.green * 255).rounded()),
            Int((style.color.blue * 255).rounded())
        )
        let fontIndex = Self.fontChoices.firstIndex { $0.name == style.fontName } ?? 0
        fontPopup.selectItem(at: fontIndex)
        boldButton.state = style.fontBold == true ? .on : .off
        switch style.textAlignment ?? .left {
        case .left: alignmentControl.selectedSegment = 0
        case .center: alignmentControl.selectedSegment = 1
        case .right: alignmentControl.selectedSegment = 2
        }
        backgroundButton.state = style.textBackground != nil ? .on : .off
        lineStyleControl.selectedSegment = style.lineStyle == .dashed ? 1 : 0
        fillButton.state = style.fillColor != nil ? .on : .off
        arrowButton.image = Self.arrowIcon(filled: style.arrowStyle != .simple, chevron: true)

        widthSlider.isHidden = isText
        fontSizeSlider.isHidden = !isText
        textRow.isHidden = !isText
        shapeRow.isHidden = !showsShapeOptions
        arrowButton.isHidden = !showsArrowStyle
        for swatch in swatches {
            swatch.isCurrentColor = swatch.rgba == style.color
        }
    }

    @objc private func colorChanged() { onColor(colorWell.color.rgbaValue) }
    @objc private func paletteChanged(_ sender: NSButton) {
        guard let swatch = sender as? ColorSwatchButton else { return }
        onColor(swatch.rgba)
    }
    @objc private func widthChanged() {
        sizeField.stringValue = Self.widthText(widthSlider.doubleValue)
        onWidth(widthSlider.doubleValue)
    }

    @objc private func fontSizeChanged() {
        sizeField.stringValue = Self.widthText(fontSizeSlider.doubleValue)
        onFontSize(fontSizeSlider.doubleValue)
    }

    @objc private func fontChanged() {
        onFontName(fontPopup.selectedItem?.representedObject as? String)
    }

    @objc private func boldChanged() {
        onBold(boldButton.state == .on)
    }

    @objc private func alignmentChanged() {
        let alignment: AnnotationTextAlignment
        switch alignmentControl.selectedSegment {
        case 1: alignment = .center
        case 2: alignment = .right
        default: alignment = .left
        }
        onAlignment(alignment)
    }

    @objc private func backgroundChanged() {
        onTextBackground(backgroundButton.state == .on)
    }

    @objc private func lineStyleChanged() {
        onLineStyle(lineStyleControl.selectedSegment == 1 ? .dashed : .solid)
    }

    @objc private func fillChanged() {
        onFill(fillButton.state == .on)
    }

    @objc private func showArrowMenu() {
        let menu = NSMenu()
        for (filled, title) in [
            (true, L10n.tr("Filled arrow head", "实心箭头")),
            (false, L10n.tr("Outline arrow head", "线框箭头")),
        ] {
            let item = NSMenuItem(title: title, action: #selector(pickArrowStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = filled
            item.image = Self.arrowIcon(filled: filled)
            menu.addItem(item)
        }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: 0),
            in: arrowButton
        )
    }

    @objc private func pickArrowStyle(_ sender: NSMenuItem) {
        onArrowStyle((sender.representedObject as? Bool) == false ? .simple : .tapered)
    }
}

/// Reports the click that starts editing; the begin-editing notification is
/// not posted reliably by NSTextField, so the mouse event is the trigger.
private final class SizeTextField: NSTextField {
    var onBeginEditing: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onBeginEditing?()
        super.mouseDown(with: event)
        // A click selects the whole number, so typing replaces it instead of
        // appending to it.
        selectText(nil)
    }
}

/// Small round color preset. Drawing it directly avoids the default NSButton
/// bezel, which would make the palette look like a row of form controls.
@MainActor
private final class ColorSwatchButton: NSButton {
    let rgba: RGBA
    /// Marks the color the panel is currently editing.
    var isCurrentColor = false {
        didSet { needsDisplay = true }
    }

    init(color: RGBA) {
        self.rgba = color
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = isCurrentColor ? 3.5 : 2
        let circle = bounds.insetBy(dx: inset, dy: inset)
        NSColor(rgba).setFill()
        NSBezierPath(ovalIn: circle).fill()
        NSColor.separatorColor.setStroke()
        let hairline = NSBezierPath(ovalIn: circle)
        hairline.lineWidth = 1
        hairline.stroke()
        if isCurrentColor {
            NSColor.labelColor.withAlphaComponent(0.85).setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            ring.stroke()
        } else if isHighlighted {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: -0.5, dy: -0.5))
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}
