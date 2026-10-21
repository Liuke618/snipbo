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
    private var keyMonitor: Any?

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
        // Cmd+C copies without closing; Enter and the toolbar Copy button copy
        // and close.
        canvas.onCopy = { [weak self] in self?.copyToPasteboard() }
        canvas.onCopyAndClose = { [weak self] in self?.copyAndClose() }
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
        installKeyMonitor()
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

    // MARK: - Shortcuts while a toolbar control has focus

    /// Routes editor shortcuts that would otherwise be consumed by a focused
    /// toolbar control (color well, slider, segmented control, buttons). The
    /// canvas and the text overlay keep handling their own key events.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window else { return event }
            // Key events normally target the key window; synthetic events can
            // carry their target window explicitly. Only handle events for this
            // editor, never for panels or other windows.
            guard window.isKeyWindow || event.window === window else { return event }
            return self.handleEditorKey(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    /// Handles the editor shortcuts when the first responder is not the canvas
    /// or the text overlay, which have their own key handling. Returns true
    /// when the event was consumed.
    func handleEditorKey(_ event: NSEvent) -> Bool {
        guard let window else { return false }
        let responder = window.firstResponder
        if responder is EditorCanvasView || responder is TextEditingOverlay {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command),
           let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "z":
                if modifiers.contains(.shift) { controller.redo() } else { controller.undo() }
                return true
            case "c":
                copyToPasteboard()
                return true
            case "s":
                saveAndClose(saveAs: modifiers.contains(.shift))
                return true
            default:
                break
            }
        }
        switch event.keyCode {
        case 36:
            copyAndClose()
            return true
        case 53:
            close()
            return true
        default:
            return false
        }
    }

    // MARK: - Copy and save

    /// Commits a pending text overlay before an action reads the document, so
    /// text still being edited is included in the export and is not lost when
    /// the window closes.
    private func commitPendingText() {
        canvas.commitPendingText()
    }

    /// Renders the document and writes it to the pasteboard, keeping the editor
    /// open. Returns false when the image could not be encoded or written.
    @discardableResult
    func copyToPasteboard() -> Bool {
        commitPendingText()
        // Encode before touching the pasteboard, so a render/encode failure
        // leaves the user's current clipboard contents intact.
        guard let image = controller.renderForExport(),
              let data = ImageExporter.pngData(from: image) else {
            reportCopyFailure()
            return false
        }
        let pasteboard = NSPasteboard.general
        let previousItems = Self.snapshotPasteboard(pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: .png) else {
            // Clearing already dropped the previous contents; put them back
            // before telling the user the copy failed.
            Self.restorePasteboard(previousItems, to: pasteboard)
            reportCopyFailure()
            return false
        }
        HistoryRecorder.record(image, source: .region, settings: settings, history: history)
        return true
    }

    /// Copies the pasteboard's items so they can be restored after a failed
    /// write. Items read from a pasteboard cannot be written back directly, so
    /// each item's data is copied into a fresh item. Split out so the
    /// snapshot/restore mechanics can be exercised without a real failure.
    static func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            let copy = NSPasteboardItem()
            var copiedAnyType = false
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                    copiedAnyType = true
                }
            }
            return copiedAnyType ? copy : nil
        }
    }

    static func restorePasteboard(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }

    private func reportCopyFailure() {
        NSLog("LightShot: failed to copy the rendered screenshot to the pasteboard")
        NSSound.beep()
        guard let window, window.isVisible else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Copy failed"
        alert.informativeText = "The screenshot could not be placed on the clipboard."
        alert.runModal()
    }

    /// Copies the rendered document and closes the editor. Enter, the toolbar
    /// Copy button, and any other "copy and finish" action use this; Cmd+C uses
    /// `copyToPasteboard()` and keeps the editor open.
    func copyAndClose() {
        guard copyToPasteboard() else { return }
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
            HistoryRecorder.record(image, source: .region, settings: settings, history: history)
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
        removeKeyMonitor()
        super.close()
    }

    func windowWillClose(_ notification: Notification) {
        commitPendingText()
        removeKeyMonitor()
        onClose()
    }
}
