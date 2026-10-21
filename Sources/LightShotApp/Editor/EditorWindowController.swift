import AppKit
import LightShotCore

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let controller: EditorController
    private let canvas: EditorCanvasView
    private let scrollView = NSScrollView()
    private let toolbar: EditorToolbarView
    private let onClose: () -> Void

    init(document: EditDocument, onClose: @escaping () -> Void = {}) {
        self.controller = EditorController(document: document)
        self.canvas = EditorCanvasView(controller: controller)
        self.onClose = onClose
        self.toolbar = EditorToolbarView(
            onTool: { [weak controller] tool in controller?.tool = tool },
            onUndo: { [weak controller] in controller?.undo() },
            onRedo: { [weak controller] in controller?.redo() }
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1000, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
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

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
