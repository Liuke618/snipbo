import AppKit
import SnipboCore

/// Floating annotation-style controls pinned to the top-right of the canvas:
/// color, its hex readout, and the stroke-width slider. The panel replaces the
/// style strip that used to widen the toolbar and only appears while a
/// style-bearing tool or annotation is active, so browsing stays unobstructed.
@MainActor
final class EditorStylePanelView: NSView {
    private let effect = NSVisualEffectView()
    private let colorWell = NSColorWell()
    private let hexLabel = NSTextField(labelWithString: "#FF0000")
    private let widthSlider = NSSlider(value: 3, minValue: 1, maxValue: 24, target: nil, action: nil)
    private let onColor: (RGBA) -> Void
    private let onWidth: (CGFloat) -> Void

    init(onColor: @escaping (RGBA) -> Void, onWidth: @escaping (CGFloat) -> Void) {
        self.onColor = onColor
        self.onWidth = onWidth
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 40))

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

        colorWell.target = self
        colorWell.action = #selector(colorChanged)
        widthSlider.target = self
        widthSlider.action = #selector(widthChanged)

        let stack = NSStackView(views: [colorWell, hexLabel, widthSlider])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)

        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 40),
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            colorWell.widthAnchor.constraint(equalToConstant: 44),
            widthSlider.widthAnchor.constraint(equalToConstant: 100),
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

    @objc private func colorChanged() { onColor(colorWell.color.rgbaValue) }
    @objc private func widthChanged() { onWidth(widthSlider.doubleValue) }
}
