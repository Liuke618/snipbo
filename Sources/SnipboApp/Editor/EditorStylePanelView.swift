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
        labels: ["Solid", "Dashed"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let fillButton = NSButton(
        checkboxWithTitle: "",
        target: nil,
        action: nil
    )
    private let arrowPopup = NSPopUpButton(frame: .zero, pullsDown: false)
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
    private var heightConstraint: NSLayoutConstraint!

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
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 9
        layer?.shadowOffset = CGSize(width: 0, height: -2)

        effect.material = .popover
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        colorWell.toolTip = L10n.tr("Annotation color", "标注颜色")
        hexLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        hexLabel.textColor = .secondaryLabelColor
        hexLabel.toolTip = L10n.tr("Press Tab to copy the color", "按 Tab 复制色值")
        widthSlider.toolTip = L10n.tr(
            "Stroke width — affects the selected annotation, or the next one you draw",
            "线条粗细 — 作用于选中的标注，或接下来绘制的标注"
        )
        widthSlider.isContinuous = true
        colorWell.controlSize = .small
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

        lineStyleControl.setLabel(L10n.tr("Solid", "实线"), forSegment: 0)
        lineStyleControl.setLabel(L10n.tr("Dashed", "虚线"), forSegment: 1)
        lineStyleControl.controlSize = .small
        lineStyleControl.selectedSegment = 0
        lineStyleControl.toolTip = L10n.tr("Line style", "线条样式")

        fillButton.title = L10n.tr("Fill", "填充")
        fillButton.controlSize = .small
        fillButton.toolTip = L10n.tr("Fill shape", "填充形状")

        arrowPopup.addItem(withTitle: L10n.tr("Tapered", "实心箭头"))
        arrowPopup.addItem(withTitle: L10n.tr("Simple", "线框箭头"))
        arrowPopup.controlSize = .small
        arrowPopup.toolTip = L10n.tr("Arrow style", "箭头样式")

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
        arrowPopup.target = self
        arrowPopup.action = #selector(arrowStyleChanged)

        let topRow = NSStackView(views: [
            colorWell, hexLabel, widthSlider, fontSizeSlider,
        ])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 8

        textRow.orientation = .horizontal
        textRow.alignment = .centerY
        textRow.spacing = 8
        textRow.addArrangedSubview(fontPopup)
        textRow.addArrangedSubview(boldButton)
        textRow.addArrangedSubview(alignmentControl)
        textRow.addArrangedSubview(backgroundButton)
        textRow.isHidden = true
        fontSizeSlider.isHidden = true

        shapeRow.orientation = .horizontal
        shapeRow.alignment = .centerY
        shapeRow.spacing = 8
        shapeRow.addArrangedSubview(lineStyleControl)
        shapeRow.addArrangedSubview(fillButton)
        shapeRow.addArrangedSubview(arrowPopup)
        shapeRow.isHidden = true

        paletteRow.orientation = .horizontal
        paletteRow.alignment = .centerY
        paletteRow.spacing = 4
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
        }

        let stack = NSStackView(views: [topRow, shapeRow, textRow, paletteRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)

        heightConstraint = heightAnchor.constraint(equalToConstant: 40)
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint,
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            colorWell.widthAnchor.constraint(equalToConstant: 44),
            widthSlider.widthAnchor.constraint(equalToConstant: 100),
            fontSizeSlider.widthAnchor.constraint(equalToConstant: 100),
            fontPopup.widthAnchor.constraint(equalToConstant: 118),
            boldButton.widthAnchor.constraint(equalToConstant: 32),
            alignmentControl.widthAnchor.constraint(equalToConstant: 92),
            lineStyleControl.widthAnchor.constraint(equalToConstant: 104),
            arrowPopup.widthAnchor.constraint(equalToConstant: 104),
        ])
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
        showsShapeOptions: Bool
    ) {
        widthSlider.doubleValue = style.lineWidth
        fontSizeSlider.doubleValue = style.fontSize
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
        arrowPopup.selectItem(at: style.arrowStyle == .simple ? 1 : 0)

        widthSlider.isHidden = isText
        fontSizeSlider.isHidden = !isText
        textRow.isHidden = !isText
        shapeRow.isHidden = !showsShapeOptions
        let target: CGFloat = (isText || showsShapeOptions) ? 112 : 72
        if heightConstraint.constant != target {
            heightConstraint.constant = target
        }
    }

    @objc private func colorChanged() { onColor(colorWell.color.rgbaValue) }
    @objc private func paletteChanged(_ sender: NSButton) {
        guard let swatch = sender as? ColorSwatchButton else { return }
        onColor(swatch.rgba)
    }
    @objc private func widthChanged() { onWidth(widthSlider.doubleValue) }
    @objc private func fontSizeChanged() { onFontSize(fontSizeSlider.doubleValue) }

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

    @objc private func arrowStyleChanged() {
        onArrowStyle(arrowPopup.indexOfSelectedItem == 1 ? .simple : .tapered)
    }
}

/// Small round color preset. Drawing it directly avoids the default NSButton
/// bezel, which would make the palette look like a row of form controls.
@MainActor
private final class ColorSwatchButton: NSButton {
    let rgba: RGBA

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
        let circle = bounds.insetBy(dx: 1, dy: 1)
        NSColor(rgba).setFill()
        NSBezierPath(ovalIn: circle).fill()
        if isHighlighted {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: -0.5, dy: -0.5))
            ring.lineWidth = 2
            ring.stroke()
        } else {
            NSColor.separatorColor.setStroke()
            let outline = NSBezierPath(ovalIn: circle)
            outline.lineWidth = 1
            outline.stroke()
        }
    }
}
