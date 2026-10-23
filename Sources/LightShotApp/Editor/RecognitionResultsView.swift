import AppKit
import LightShotCore

/// Side panel showing the latest OCR text and barcode payloads. The text view
/// is read-only but selectable, so a single block can be copied by selecting
/// it; Copy All copies text and barcode payloads together.
@MainActor
final class RecognitionResultsView: NSView {
    var onCopy: ((String) -> Void)?
    var onClose: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Recognition")
    private let statusLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy All", target: nil, action: nil)
    private let scrollView = NSScrollView()
    private let textView = NSTextView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

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

        showMessage("Click Recognize to read text and barcodes from the current image.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func showProgress() {
        showMessage("Recognizing…")
    }

    func showMessage(_ message: String) {
        textView.string = message
        statusLabel.stringValue = ""
        copyButton.isEnabled = false
    }

    func show(_ result: RecognitionResult) {
        textView.string = result.plainText
        statusLabel.stringValue = "\(result.textBlocks.count) text blocks · \(result.barcodes.count) barcodes"
        copyButton.isEnabled = !result.plainText.isEmpty
    }

    @objc private func copyAction() {
        guard !textView.string.isEmpty else { return }
        onCopy?(textView.string)
    }

    @objc private func closeAction() {
        onClose?()
    }
}
