import AppKit
import LightShotCore

/// Shottr-style options popover: the logical-points readout toggle and the
/// destructive image resize with scale presets and custom width/height.
/// Lives as long as its editor window; the document is only read when the
/// popover opens and mutated by the Resize action.
@MainActor
final class EditorOptionsPanelController: NSViewController, NSTextFieldDelegate {
    private weak var editorController: EditorController?
    private let pointsToggle = NSSwitch()
    private let scaleControl = NSSegmentedControl(
        labels: ["25%", "33%", "50%", "1×", "2×", "4×"],
        trackingMode: .momentary,
        target: nil,
        action: nil
    )
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let resizeButton = NSButton(title: "", target: nil, action: nil)
    private let currentSizeLabel = NSTextField(labelWithString: "")
    private var isSyncingFields = false
    /// Scale factors behind the preset segments, in order.
    private static let presetFactors: [CGFloat] = [0.25, 1.0 / 3.0, 0.5, 1, 2, 4]

    init(controller: EditorController) {
        self.editorController = controller
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let title = NSTextField(labelWithString: L10n.tr("Show Size in Logical Points", "以逻辑点显示尺寸"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let caption = NSTextField(wrappingLabelWithString: L10n.tr(
            "One logical point equals two physical pixels on Retina displays. Press ⇧P to switch.",
            "Retina 屏上一个逻辑点等于两个物理像素。按 ⇧P 切换。"
        ))
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.preferredMaxLayoutWidth = 280

        pointsToggle.target = self
        pointsToggle.action = #selector(pointsChanged)
        pointsToggle.controlSize = .small

        let resizeTitle = NSTextField(labelWithString: L10n.tr("Resize Image", "调整图像大小"))
        resizeTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let resizeNote = NSTextField(labelWithString: L10n.tr("(can't be undone!)", "（不可撤销！）"))
        resizeNote.font = .systemFont(ofSize: 11)
        resizeNote.textColor = .secondaryLabelColor

        scaleControl.target = self
        scaleControl.action = #selector(presetPicked)
        scaleControl.controlSize = .small
        scaleControl.selectedSegment = 3

        for field in [widthField, heightField] {
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            field.alignment = .right
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 64).isActive = true
        }
        currentSizeLabel.font = .systemFont(ofSize: 11)
        currentSizeLabel.textColor = .secondaryLabelColor

        resizeButton.title = L10n.tr("Resize", "应用")
        resizeButton.bezelStyle = .rounded
        resizeButton.controlSize = .regular
        resizeButton.target = self
        resizeButton.action = #selector(resizePicked)
        resizeButton.keyEquivalent = "\r"

        let pxLabel = NSTextField(labelWithString: "px")
        pxLabel.font = .systemFont(ofSize: 11)
        pxLabel.textColor = .secondaryLabelColor

        let pointsRow = NSStackView(views: [title, pointsToggle])
        pointsRow.orientation = .horizontal
        let resizeTitleRow = NSStackView(views: [resizeTitle, resizeNote])
        resizeTitleRow.orientation = .horizontal
        let fieldsRow = NSStackView(views: [widthField, NSTextField(labelWithString: "×"), heightField, pxLabel])
        fieldsRow.orientation = .horizontal
        let resizeRow = NSStackView(views: [fieldsRow, currentSizeLabel, NSView(), resizeButton])
        resizeRow.orientation = .horizontal

        let divider = Self.separator()
        let stack = NSStackView(views: [
            pointsRow, caption, divider, resizeTitleRow, scaleControl, resizeRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(14, after: caption)
        stack.setCustomSpacing(14, after: divider)

        // Keep the resize row spread across the popover width.
        resizeRow.translatesAutoresizingMaskIntoConstraints = false
        resizeRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 190))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])
        view = container
    }

    private static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    /// Syncs every control from the document before the popover is shown.
    func refreshFromController() {
        guard let controller = editorController else { return }
        pointsToggle.state = controller.showsLogicalPoints ? .on : .off
        let crop = controller.document.cropRect
        isSyncingFields = true
        widthField.stringValue = "\(Int(crop.width.rounded()))"
        heightField.stringValue = "\(Int(crop.height.rounded()))"
        isSyncingFields = false
        currentSizeLabel.stringValue = controller.sizeText(for: crop.size)
    }

    @objc private func pointsChanged() {
        guard let controller = editorController else { return }
        controller.showsLogicalPoints = pointsToggle.state == .on
        controller.changed()
        currentSizeLabel.stringValue = controller.sizeText(
            for: controller.document.cropRect.size
        )
    }

    @objc private func presetPicked() {
        guard let controller = editorController else { return }
        let index = scaleControl.selectedSegment
        guard index >= 0, index < Self.presetFactors.count else { return }
        let factor = Self.presetFactors[index]
        let crop = controller.document.cropRect
        let width = max(8, (crop.width * factor).rounded())
        isSyncingFields = true
        widthField.stringValue = "\(Int(width))"
        heightField.stringValue = "\(Int(max(8, (crop.height * factor).rounded())))"
        isSyncingFields = false
    }

    func controlTextDidChange(_ notification: Notification) {
        guard !isSyncingFields, let controller = editorController else { return }
        let crop = controller.document.cropRect
        let aspect = crop.height / crop.width
        isSyncingFields = true
        // Editing one field re-derives the other from the current aspect, so
        // resizes stay uniform and annotations never distort.
        if notification.object as? NSTextField === widthField,
           let width = Double(widthField.stringValue), width >= 8 {
            heightField.stringValue = "\(Int((CGFloat(width) * aspect).rounded()))"
        } else if notification.object as? NSTextField === heightField,
                  let height = Double(heightField.stringValue), height >= 8 {
            widthField.stringValue = "\(Int((CGFloat(height) / aspect).rounded()))"
        }
        isSyncingFields = false
    }

    @objc private func resizePicked() {
        guard let controller = editorController,
              let width = Double(widthField.stringValue), width >= 8 else {
            NSSound.beep()
            return
        }
        controller.resizeImage(toWidth: CGFloat(width))
        view.window?.performClose(nil)
    }
}
