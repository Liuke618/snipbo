import AppKit
import LightShotCore
import UniformTypeIdentifiers

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let controller: EditorController
    private let canvas: EditorCanvasView
    private let scrollView = NSScrollView()
    private let settings: AppSettings
    private let history: HistoryStore
    private let onClose: () -> Void

    init(
        document: EditDocument,
        settings: AppSettings,
        history: HistoryStore,
        onClose: @escaping () -> Void = {}
    ) {
        self.controller = EditorController(document: document)
        self.settings = settings
        self.history = history
        self.canvas = EditorCanvasView(controller: controller)
        self.onClose = onClose
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1000, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        // The toolbar's actions call back into this controller, so it is built
        // after `super.init` when `self` can be captured.
        let toolbar = EditorToolbarView(
            onTool: { [weak controller] tool in controller?.tool = tool },
            onUndo: { [weak controller] in controller?.undo() },
            onRedo: { [weak controller] in controller?.redo() },
            onColor: { [weak controller] color in controller?.style.color = color },
            onWidth: { [weak controller] width in controller?.style.lineWidth = width },
            onCopy: { [weak self] in self?.copyAndClose() },
            onSave: { [weak self] in self?.saveAndClose(saveAs: false) },
            onClose: { [weak self] in self?.close() }
        )
        window.title = "LightShot"
        window.center()
        window.delegate = self
        controller.canvas = canvas
        controller.onCropChanged = { [weak self] in self?.fitToWindow() }
        canvas.onFit = { [weak self] in self?.fitToWindow() }
        canvas.onActualSize = { [weak self] in self?.canvas.setZoom(1) }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.documentView = canvas

        let content = NSStackView(views: [toolbar, scrollView])
        content.orientation = .vertical
        content.spacing = 0
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = content
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        canvas.onCopy = { [weak self] in self?.copyAndClose() }
        canvas.onSave = { [weak self] in self?.saveAndClose(saveAs: false) }
        canvas.onSaveAs = { [weak self] in self?.saveAndClose(saveAs: true) }
        canvas.onEscape = { [weak self] in self?.close() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.layoutIfNeeded()
        fitToWindow()
        window?.makeFirstResponder(canvas)
    }

    func fitToWindow() {
        let content = scrollView.contentSize
        let crop = controller.document.cropRect
        guard content.width > 1, content.height > 1, crop.width > 0, crop.height > 0 else { return }
        let scale = min(
            content.width / crop.width,
            content.height / crop.height,
            1
        )
        canvas.setZoom(scale)
    }

    /// Commits a pending text overlay before an action reads the document, so
    /// text still being edited is included in the export and is not lost when
    /// the window closes.
    private func commitPendingText() {
        canvas.commitPendingText()
    }

    private func copyAndClose() {
        commitPendingText()
        guard let image = controller.renderForExport(),
              let data = ImageExporter.pngData(from: image) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        Task { try? await history.record(image: ImageData(image), source: .region) }
        close()
    }

    private func saveAndClose(saveAs: Bool) {
        commitPendingText()
        guard let image = controller.renderForExport() else { return }
        let fileName = controller.defaultFileName(format: settings.format)
        let url: URL
        if saveAs {
            let panel = savePanel(fileName: fileName)
            guard panel.runModal() == .OK, let selected = panel.url else { return }
            url = selected
        } else {
            url = URL(fileURLWithPath: settings.saveDirectory).appendingPathComponent(fileName)
        }
        do {
            try controller.write(image, to: url, format: settings.format, quality: settings.jpegQuality)
            Task { try? await history.record(image: ImageData(image), source: .region) }
            close()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Builds the Save As panel for the configured output format. Split out so
    /// the panel configuration can be inspected without running it modally.
    func savePanel(fileName: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = settings.format == .png ? [.png] : [.jpeg]
        return panel
    }

    override func close() {
        commitPendingText()
        super.close()
    }

    func windowWillClose(_ notification: Notification) {
        commitPendingText()
        onClose()
    }
}
