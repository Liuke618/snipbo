import AppKit
import SnipboCore

/// Side panel showing the latest OCR text and barcode payloads. The text view
/// is read-only but selectable, so a single block can be copied by selecting
/// it; Copy All copies text and barcode payloads together.
@MainActor
final class RecognitionResultsView: NSView {
    var onCopy: ((String) -> Void)?
    var onClose: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: L10n.tr("Recognition", "识别"))
    private let statusLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: L10n.tr("Close", "关闭"), target: nil, action: nil)
    private let copyButton = NSButton(title: L10n.tr("Copy All", "复制全部"), target: nil, action: nil)
    private let scrollView = NSScrollView()
    private let textView = NSTextView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let background = MaterialBackgroundView()
        addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let edge = SeparatorEdgeView(frame: .zero)
        edge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(edge)
        NSLayoutConstraint.activate([
            edge.leadingAnchor.constraint(equalTo: leadingAnchor),
            edge.topAnchor.constraint(equalTo: topAnchor),
            edge.bottomAnchor.constraint(equalTo: bottomAnchor),
            edge.widthAnchor.constraint(equalToConstant: 1),
        ])

        titleLabel.font = DesignTokens.titleFont
        statusLabel.font = DesignTokens.metaFont
        statusLabel.textColor = DesignTokens.Color.textSecondary

        closeButton.controlSize = .small
        copyButton.controlSize = .small
        closeButton.target = self
        closeButton.action = #selector(closeAction)
        copyButton.target = self
        copyButton.action = #selector(copyAction)

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 12)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.frame = CGRect(x: 0, y: 0, width: 260, height: 400)
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView

        for view in [titleLabel, statusLabel, closeButton, copyButton, scrollView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -8),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            copyButton.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            copyButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            copyButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])

        showMessage(L10n.tr(
            "Click Recognize to read text and barcodes from the current image.",
            "点击“识别”读取当前图像中的文字和条码。"
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func showProgress() {
        showMessage(L10n.tr("Recognizing…", "识别中…"))
    }

    func showMessage(_ message: String) {
        textView.string = message
        statusLabel.stringValue = ""
        copyButton.isEnabled = false
    }

    func show(_ result: RecognitionResult, removeLineBreaks: Bool) {
        let text = result.plainText(removeLineBreaks: removeLineBreaks)
        textView.string = text
        statusLabel.stringValue = L10n.tr(
            "\(result.textBlocks.count) text blocks · \(result.barcodes.count) barcodes",
            "\(result.textBlocks.count) 段文字 · \(result.barcodes.count) 个条码"
        )
        copyButton.isEnabled = !text.isEmpty
    }

    @objc private func copyAction() {
        guard !textView.string.isEmpty else { return }
        onCopy?(textView.string)
    }

    @objc private func closeAction() {
        onClose?()
    }
}

/// The panel's 1pt leading edge, painted from the token stroke.
@MainActor
private final class SeparatorEdgeView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        DesignTokens.Color.stroke.setFill()
        bounds.fill()
    }
}
