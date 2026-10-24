import AppKit
import LightShotCore
import UniformTypeIdentifiers

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    /// Identifies this editor instance. Callers that retain several editors at
    /// once use it to remove exactly the editor whose close callback runs.
    let identifier: UUID
    let controller: EditorController
    private let canvas: EditorCanvasView
    /// The canvas the editor draws into; exposed for probes and programmatic
    /// zoom checks.
    var canvasView: EditorCanvasView { canvas }
    private let scrollView = NSScrollView()
    /// Read at action time so open editors follow live settings changes
    /// (history toggle, save directory, format, JPEG quality).
    private let settingsProvider: () -> AppSettings
    private var settings: AppSettings { settingsProvider() }
    private let history: HistoryStore
    private let pasteboard: any PasteboardWriting
    private let onClose: () -> Void
    private var keyMonitor: Any?
    private let recognitionService: RecognitionService
    private let recognitionPanel: RecognitionResultsView
    private let bodyView = NSView(frame: .zero)
    private var recognitionPanelConstraints: [NSLayoutConstraint] = []
    private var scrollTrailingConstraint: NSLayoutConstraint!
    private var recognitionTask: Task<Void, Never>?
    /// Invalidates stale tasks after cancel or a newer recognition request.
    private var recognitionGeneration = 0
    private var toolbarView: EditorToolbarView?

    init(
        document: EditDocument,
        settingsProvider: @escaping () -> AppSettings,
        history: HistoryStore,
        identifier: UUID = UUID(),
        pasteboard: any PasteboardWriting = NSPasteboard.general,
        onClose: @escaping () -> Void = {}
    ) {
        self.recognitionService = RecognitionService.shared
        self.recognitionPanel = RecognitionResultsView(frame: .zero)
        self.identifier = identifier
        self.controller = EditorController(document: document)
        self.settingsProvider = settingsProvider
        self.history = history
        self.pasteboard = pasteboard
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
            onColor: { [weak controller] color in controller?.setColor(color) },
            onWidth: { [weak controller] width in controller?.setLineWidth(width) },
            onRecognize: { [weak self] in self?.recognize() },
            onPin: { [weak self] in self?.pinAction() },
            onCopy: { [weak self] in self?.copyAndClose() },
            onSave: { [weak self] in self?.saveAndClose(saveAs: false) },
            onShowOptions: { [weak self] in self?.showOptionsPopover() }
        )
        self.toolbarView = toolbar
        window.title = "LightShot"
        window.center()
        window.delegate = self
        controller.canvas = canvas
        controller.onCropChanged = { [weak self] in self?.fitToWindow() }
        controller.onChange = { [weak self] in self?.refreshReadouts() }
        canvas.onFit = { [weak self] in self?.fitToWindow() }
        canvas.onActualSize = { [weak self] in
            self?.canvas.setZoom(1)
            self?.refreshReadouts()
        }
        canvas.onZoomChanged = { [weak self] in self?.refreshReadouts() }

        // A centered clip view keeps the crop in the middle of the viewport
        // when it is smaller than the window instead of hugging the top-left
        // corner of a large empty mat. The canvas posts frame changes so the
        // clip view re-constrains when a zoom or crop resizes the document.
        canvas.postsFrameChangedNotifications = true
        scrollView.contentView = CenteringClipView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .windowBackgroundColor
        scrollView.documentView = canvas

        let body = bodyView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        recognitionPanel.translatesAutoresizingMaskIntoConstraints = false
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(scrollView)
        body.addSubview(toolbar)

        scrollTrailingConstraint = scrollView.trailingAnchor.constraint(equalTo: body.trailingAnchor)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: body.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: EditorToolbarView.height),
            scrollView.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            scrollTrailingConstraint,
        ])

        let contentView = NSView(frame: .zero)
        body.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(body)
        window.contentView = contentView
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            body.topAnchor.constraint(equalTo: contentView.topAnchor),
            body.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        refreshReadouts()
        // Cmd+C copies without closing; Enter and the toolbar Copy button copy
        // and close.
        canvas.onCopy = { [weak self] in self?.copyToPasteboard() }
        canvas.onCopyAndClose = { [weak self] in self?.copyAndClose() }
        canvas.onPin = { [weak self] in self?.pinAction() }
        canvas.onSave = { [weak self] in self?.saveAndClose(saveAs: false) }
        canvas.onSaveAs = { [weak self] in self?.saveAndClose(saveAs: true) }
        canvas.onEscape = { [weak self] in self?.escapeAction() }
        canvas.onCopyColor = { [weak self] in self?.copyColorHex() }
        recognitionPanel.onCopy = { [weak self] text in
            self?.copyRecognitionText(text)
        }
        recognitionPanel.onClose = { [weak self] in
            self?.hideRecognitionPanel()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        sizeWindowToFitImage()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.layoutIfNeeded()
        fitToWindow()
        installKeyMonitor()
        window?.makeFirstResponder(canvas)
    }

    /// Opens the window hugging the capture's displayed size: the image is
    /// first fit into 90% of the screen, then the window takes exactly that
    /// fitted size (floored at a usable editor width) and centers on screen.
    /// The screenshot therefore fills the editor instead of floating in a
    /// large empty mat; small captures still open 1:1.
    private func sizeWindowToFitImage() {
        guard let window else { return }
        let crop = controller.document.cropRect
        guard crop.width > 1, crop.height > 1 else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let maxContentWidth = visible.width * 0.9
        let maxScrollHeight = visible.height * 0.9
        let fitZoom = min(
            maxContentWidth / crop.width,
            maxScrollHeight / crop.height,
            1
        )
        let width = min(max(640, crop.width * fitZoom), maxContentWidth)
        let height = min(max(320, crop.height * fitZoom), maxScrollHeight) + EditorToolbarView.height
        window.setContentSize(NSSize(width: width, height: height))
        window.center()
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
        refreshReadouts()
    }

    /// Live title-bar readouts: the crop draft's size while cropping, else the
    /// current crop size, plus the zoom level. Also mirrors the style being
    /// edited — the selected annotation's, or the default for new annotations
    /// — into the color well, hex label, and width slider.
    private func refreshReadouts() {
        let size = controller.cropDraft?.size ?? controller.document.cropRect.size
        toolbarView?.updateReadouts(size: size, zoom: canvas.zoom)
        toolbarView?.setSelectedTool(controller.tool)
        let editedStyle = controller.selectedStyle ?? controller.style
        toolbarView?.syncStyleControls(lineWidth: editedStyle.lineWidth, color: editedStyle.color)
    }

    // MARK: - Options popover

    private var optionsPopover: NSPopover?
    private lazy var optionsPanel = EditorOptionsPanelController(controller: controller)

    private func showOptionsPopover() {
        let popover: NSPopover
        if let existing = optionsPopover {
            popover = existing
        } else {
            popover = NSPopover()
            popover.contentViewController = optionsPanel
            popover.behavior = .transient
            optionsPopover = popover
        }
        optionsPanel.refreshFromController()
        if let anchor = toolbarView?.optionsAnchor {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
    }

    /// Tab on the canvas: copies the edited color as "#RRGGBB".
    private func copyColorHex() {
        let color = (controller.selectedStyle ?? controller.style).color
        let hex = String(
            format: "#%02X%02X%02X",
            Int((color.red * 255).rounded()),
            Int((color.green * 255).rounded()),
            Int((color.blue * 255).rounded())
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(hex, forType: .string)
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
        // The results panel owns its text-selection and button shortcuts.
        if let view = responder as? NSView, view.isDescendant(of: recognitionPanel) {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // An active crop draft owns Enter (commit) and Escape (cancel), even
        // when a toolbar control has focus.
        if controller.cropDraft != nil {
            switch event.keyCode {
            case 36:
                controller.commitCropDraft()
                return true
            case 53:
                controller.cancelCropDraft()
                return true
            default:
                break
            }
        }
        if modifiers.contains(.command),
           let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "z":
                if modifiers.contains(.shift) { controller.redo() } else { controller.undo() }
                return true
            case "c":
                copyToPasteboard()
                return true
            case "p":
                pinAction()
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
            escapeAction()
            return true
        default:
            return false
        }
    }

    // MARK: - Copy and save

    /// Pins the rendered image as a floating window and closes the editor.
    /// Pins are not recorded to history.
    func pinAction() {
        commitPendingText()
        guard let image = controller.renderForExport() else { return }
        PinBoard.shared.pin(image)
        close()
    }

    /// Esc closes the editor, optionally copying and/or saving the rendered
    /// image first (Shottr's "Action when hiding with Esc").
    private func escapeAction() {
        commitPendingText()
        if settings.copyOnEditorEscape {
            copyToPasteboard()
        }
        if settings.saveOnEditorEscape {
            saveSilently()
        }
        close()
    }

    /// Writes the rendered document to the configured save directory without
    /// any panel or close side effect; used by the Esc-save option.
    private func saveSilently() {
        let settings = self.settings
        guard let image = controller.renderForExport() else { return }
        let url = URL(fileURLWithPath: settings.saveDirectory)
            .appendingPathComponent(controller.defaultFileName(format: settings.format))
        do {
            try controller.write(image, to: url, format: settings.format, quality: settings.jpegQuality)
        } catch {
            NSSound.beep()
            NSLog("LightShot: Esc-save failed: \(error.localizedDescription)")
        }
    }

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
        let pasteboard = self.pasteboard
        guard PasteboardWriter.writePNG(data, to: pasteboard) else {
            // The helper already put the previous contents back before
            // telling the user the copy failed.
            reportCopyFailure()
            return false
        }
        // No history record here: the capture was recorded on delivery, and
        // re-recording the rendered copy would duplicate the entry.
        return true
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
        // Snapshot the live settings once so the file name, directory, format,
        // and quality all come from the same action-time values.
        let settings = self.settings
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

    // MARK: - Recognition

    private func recognize() {
        guard recognitionTask == nil else { return }
        commitPendingText()
        guard let image = controller.renderForExport() else { return }
        let languages = settings.ocrLanguages
        recognitionGeneration += 1
        let generation = recognitionGeneration

        setRecognitionPanelVisible(true)
        recognitionPanel.showProgress()
        toolbarView?.setRecognizing(true)
        canvas.setRecognitionHighlights([])

        recognitionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.recognitionService.recognize(
                    ImageData(image),
                    languages: languages
                )
                try Task.checkCancellation()
                guard generation == self.recognitionGeneration else { return }
                self.recognitionTask = nil
                self.toolbarView?.setRecognizing(false)

                if result.isEmpty {
                    self.recognitionPanel.showMessage(L10n.tr("No text or barcode found.", "未识别到文字或条码。"))
                    NSSound.beep()
                    return
                }

                self.recognitionPanel.show(result, removeLineBreaks: settings.ocrRemoveLineBreaks)
                // Vision boxes are relative to the rendered crop; the canvas
                // works in original-image coordinates.
                let origin = self.controller.document.cropRect.origin
                let textRects = result.textBlocks.map {
                    $0.pixelRect(imageWidth: image.width, imageHeight: image.height)
                        .offsetBy(dx: origin.x, dy: origin.y)
                }
                let barcodeRects = result.barcodes.map {
                    $0.pixelRect(imageWidth: image.width, imageHeight: image.height)
                        .offsetBy(dx: origin.x, dy: origin.y)
                }
                self.canvas.setRecognitionHighlights(textRects + barcodeRects)
            } catch is CancellationError {
                guard generation == self.recognitionGeneration else { return }
                self.recognitionTask = nil
                self.toolbarView?.setRecognizing(false)
            } catch {
                guard generation == self.recognitionGeneration else { return }
                self.recognitionTask = nil
                self.toolbarView?.setRecognizing(false)
                self.recognitionPanel.showMessage(error.localizedDescription)
                NSSound.beep()
            }
        }
    }

    private func copyRecognitionText(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func setRecognitionPanelVisible(_ visible: Bool) {
        if visible {
            guard recognitionPanel.superview == nil else { return }
            bodyView.addSubview(recognitionPanel)
            recognitionPanelConstraints = [
                recognitionPanel.leadingAnchor.constraint(equalTo: scrollView.trailingAnchor),
                recognitionPanel.trailingAnchor.constraint(equalTo: bodyView.trailingAnchor),
                recognitionPanel.topAnchor.constraint(equalTo: bodyView.topAnchor),
                recognitionPanel.bottomAnchor.constraint(equalTo: bodyView.bottomAnchor),
                recognitionPanel.widthAnchor.constraint(equalToConstant: 300),
            ]
            scrollTrailingConstraint.isActive = false
            NSLayoutConstraint.activate(recognitionPanelConstraints)
        } else {
            guard recognitionPanel.superview != nil else { return }
            NSLayoutConstraint.deactivate(recognitionPanelConstraints)
            recognitionPanelConstraints.removeAll()
            recognitionPanel.removeFromSuperview()
            scrollTrailingConstraint.isActive = true
        }
        window?.layoutIfNeeded()
    }

    private func hideRecognitionPanel() {
        cancelRecognition()
        setRecognitionPanelVisible(false)
        canvas.setRecognitionHighlights([])
        window?.makeFirstResponder(canvas)
    }

    private func cancelRecognition() {
        recognitionGeneration += 1
        recognitionTask?.cancel()
        recognitionTask = nil
        toolbarView?.setRecognizing(false)
    }

    override func close() {
        commitPendingText()
        cancelRecognition()
        removeKeyMonitor()
        super.close()
    }

    func windowWillClose(_ notification: Notification) {
        commitPendingText()
        cancelRecognition()
        removeKeyMonitor()
        onClose()
    }
}

/// Clip view that centers a document view smaller than the viewport by
/// allowing the visible-rect origin to go negative on the short axes. It reads
/// the document view's frame rather than `documentRect`, which this macOS
/// version clamps up to the viewport once layout settles. Gestures over the
/// background mat are forwarded to the canvas so pinch zoom works everywhere.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedVisibleRect: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedVisibleRect)
        guard let documentFrame = documentView?.frame else { return rect }
        if documentFrame.width < bounds.width {
            rect.origin.x = (documentFrame.width - bounds.width) / 2
        }
        if documentFrame.height < bounds.height {
            rect.origin.y = (documentFrame.height - bounds.height) / 2
        }
        return rect
    }

    override func magnify(with event: NSEvent) {
        if let canvas = documentView as? EditorCanvasView {
            canvas.magnify(with: event)
        } else {
            super.magnify(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let canvas = documentView as? EditorCanvasView {
            canvas.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}
