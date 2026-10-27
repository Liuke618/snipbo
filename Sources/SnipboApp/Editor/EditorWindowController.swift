import AppKit
import SnipboCore
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
    private let metadata: CaptureMetadata?
    private let pasteboard: any PasteboardWriting
    private let onClose: () -> Void
    /// The history entry this editor belongs to, attached after the async
    /// record completes (or immediately for a history-opened editor).
    private var historyEntryID: UUID?
    private var snapshotSaveTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private let recognitionService: RecognitionService
    private let recognitionPanel: RecognitionResultsView
    private let bodyView = NSView(frame: .zero)
    private var recognitionPanelConstraints: [NSLayoutConstraint] = []
    private var scrollTrailingConstraint: NSLayoutConstraint!
    private var recognitionTask: Task<Void, Never>?
    /// Invalidates stale tasks after cancel or a newer recognition request.
    private var recognitionGeneration = 0
    private var redactionTask: Task<Void, Never>?
    private var redactionGeneration = 0
    /// Prevents a second copy/save/pin from starting while the first render or
    /// encode is still in flight.
    private var exportInFlight = false
    private var toolbarView: EditorToolbarView?
    private var stylePanel: EditorStylePanelView?
    private var stylePanelTopConstraint: NSLayoutConstraint?
    private var stylePanelTrailingConstraint: NSLayoutConstraint?
    private var stylePanelLeadingConstraint: NSLayoutConstraint?
    private var stylePanelPinnedToTrailing = true
    /// Exposed for probes: the floating style panel over the canvas.
    var stylePanelView: EditorStylePanelView? { stylePanel }

    init(
        document: EditDocument,
        settingsProvider: @escaping () -> AppSettings,
        history: HistoryStore,
        identifier: UUID = UUID(),
        historyEntryID: UUID? = nil,
        metadata: CaptureMetadata? = nil,
        pasteboard: any PasteboardWriting = NSPasteboard.general,
        onClose: @escaping () -> Void = {}
    ) {
        self.recognitionService = RecognitionService.shared
        self.recognitionPanel = RecognitionResultsView(frame: .zero)
        self.identifier = identifier
        self.controller = EditorController(document: document)
        self.historyEntryID = historyEntryID
        self.settingsProvider = settingsProvider
        self.history = history
        self.metadata = metadata
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
            onRedact: { [weak self] mode in self?.redact(mode) },
            onRecognize: { [weak self] in self?.recognize() },
            onPin: { [weak self] in self?.pinAction() },
            onCopy: { [weak self] in self?.copyAndClose() },
            onSave: { [weak self] in self?.saveAndClose(saveAs: false) },
            onShowOptions: { [weak self] in self?.showOptionsPopover() }
        )
        self.toolbarView = toolbar
        let stylePanel = EditorStylePanelView(
            onColor: { [weak controller] color in controller?.setColor(color) },
            onWidth: { [weak controller] width in controller?.setLineWidth(width) },
            onFontSize: { [weak controller] size in controller?.setFontSize(size) },
            onFontName: { [weak controller] name in controller?.setFontName(name) },
            onBold: { [weak controller] bold in controller?.setFontBold(bold) },
            onAlignment: { [weak controller] alignment in
                controller?.setTextAlignment(alignment)
            },
            onTextBackground: { [weak controller] enabled in
                controller?.setTextBackground(
                    enabled ? RGBA(red: 0, green: 0, blue: 0, alpha: 0.55) : nil
                )
            },
            onLineStyle: { [weak controller] lineStyle in
                controller?.setLineStyle(lineStyle)
            },
            onFill: { [weak controller] enabled in
                controller?.setFillEnabled(enabled)
            },
            onArrowStyle: { [weak controller] arrowStyle in
                controller?.setArrowStyle(arrowStyle)
            }
        )
        self.stylePanel = stylePanel
        stylePanel.onMove = { [weak self] delta in self?.moveStylePanel(by: delta) }
        stylePanel.onFinishEditing = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.canvas)
        }
        window.title = "Snipbo"
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
        body.addSubview(stylePanel)

        scrollTrailingConstraint = scrollView.trailingAnchor.constraint(equalTo: body.trailingAnchor)
        // Anchored to the canvas viewport rather than the window so the panel
        // moves aside with the canvas when the recognition panel opens, and
        // floats above the image instead of taking layout space.
        let stylePanelTop = stylePanel.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 12)
        let stylePanelTrailing = stylePanel.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -12)
        stylePanelTopConstraint = stylePanelTop
        stylePanelTrailingConstraint = stylePanelTrailing
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: body.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: EditorToolbarView.height),
            scrollView.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            scrollTrailingConstraint,
            stylePanelTop,
            stylePanelTrailing,
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
        canvas.onCopy = { [weak self] in
            Task { await self?.copyToPasteboard() }
        }
        canvas.onCopyAndClose = { [weak self] in self?.copyAndClose() }
        canvas.onPin = { [weak self] in self?.pinAction() }
        canvas.onSave = { [weak self] in self?.saveAndClose(saveAs: false) }
        canvas.onSaveAs = { [weak self] in self?.saveAndClose(saveAs: true) }
        canvas.onEscape = { [weak self] in self?.escapeAction() }
        canvas.onCopyColor = { [weak self] in self?.copyColorHex() }
        canvas.onRedact = { [weak self] mode in self?.redact(mode) }
        canvas.suggestedExportName = { [weak self] in
            self?.defaultFileName(format: .png) ?? "Snipbo.png"
        }
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
        // A small capture still needs room for every tool and action; the
        // toolbar would otherwise clip on the right. The floor is measured
        // from the live view, so adding a tool never silently hides another.
        let toolbarFloor = toolbarView?.fittingSize.width ?? 640
        let width = min(
            max(640, crop.width * fitZoom, toolbarFloor),
            maxContentWidth
        )
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

    /// Live readouts: the crop draft's size while cropping, else the current
    /// crop size, plus the zoom level. Also mirrors the style being edited —
    /// the selected annotation's, or the default for new annotations — into
    /// the floating panel, which only shows when it can affect something.
    private func refreshReadouts() {
        let size = controller.cropDraft?.size ?? controller.document.cropRect.size
        toolbarView?.updateReadouts(size: size, zoom: canvas.zoom)
        toolbarView?.setSelectedTool(controller.tool)
        let editedStyle = controller.selectedStyle ?? controller.style
        let isText = controller.tool == .text || controller.selectedKind == .text
        let shapeTools: [EditorTool] = [
            .rectangle, .ellipse, .line, .arrow, .measure, .polygon,
        ]
        let shapeKinds: [AnnotationKind] = [
            .rectangle, .ellipse, .line, .arrow, .measure, .polygon,
        ]
        let shapeSelected = controller.selectedKind.map { shapeKinds.contains($0) } ?? false
        let showsShapeOptions = !isText
            && (shapeTools.contains(controller.tool) || shapeSelected)
        // Only arrows have a head style: show the control for an arrow
        // selection, or while the arrow tool draws without a selection.
        let showsArrowStyle = controller.selectedKind == .arrow
            || (controller.selectedStyle == nil && controller.tool == .arrow)
        stylePanel?.syncStyleControls(
            style: editedStyle,
            isText: isText,
            showsShapeOptions: showsShapeOptions,
            showsArrowStyle: showsArrowStyle
        )
        stylePanel?.isHidden = controller.selectedStyle == nil
            && (controller.tool == .select || controller.tool == .crop)
        scheduleDocumentSnapshot()
    }

    /// The panel starts pinned to the canvas corner. The first drag trades the
    /// trailing anchor for a leading one, so it keeps whatever spot the user
    /// drops it on instead of snapping back over the image.
    private func moveStylePanel(by delta: CGSize) {
        guard let panel = stylePanel else { return }
        if stylePanelPinnedToTrailing, let trailing = stylePanelTrailingConstraint {
            stylePanelPinnedToTrailing = false
            trailing.isActive = false
            let leading = panel.leadingAnchor.constraint(
                equalTo: scrollView.leadingAnchor,
                constant: panel.frame.minX - scrollView.frame.minX
            )
            leading.isActive = true
            stylePanelLeadingConstraint = leading
        }
        guard let leading = stylePanelLeadingConstraint,
              let top = stylePanelTopConstraint else { return }
        let viewport = scrollView.frame.size
        let size = panel.frame.size
        let maxX = max(8, viewport.width - size.width - 8)
        let maxY = max(8, viewport.height - size.height - 8)
        leading.constant = min(max(8, leading.constant + delta.width), maxX)
        // Window coordinates grow upward, constraint constants downward.
        top.constant = min(max(8, top.constant - delta.height), maxY)
    }

    /// Keeps a dragged panel inside the viewport when the window shrinks.
    private func clampStylePanel() {
        guard let leading = stylePanelLeadingConstraint,
              let top = stylePanelTopConstraint,
              let panel = stylePanel else { return }
        let viewport = scrollView.frame.size
        let size = panel.frame.size
        leading.constant = min(max(8, leading.constant), max(8, viewport.width - size.width - 8))
        top.constant = min(max(8, top.constant), max(8, viewport.height - size.height - 8))
    }

    func windowDidResize(_ notification: Notification) {
        clampStylePanel()
    }

    /// Debounces snapshot writes while the user draws or adjusts a crop.
    private func scheduleDocumentSnapshot() {
        guard historyEntryID != nil else { return }
        snapshotSaveTask?.cancel()
        snapshotSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self else { return }
            self.persistDocumentSnapshot()
        }
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
        // While a field editor is active (the style panel's size readout), the
        // field owns typing, Return, and ⌘A — otherwise Return would copy and
        // close the editor out from under the user.
        if let textView = responder as? NSTextView, textView.isFieldEditor {
            return false
        }
        // The results panel owns its text-selection and button shortcuts.
        if let view = responder as? NSView, view.isDescendant(of: recognitionPanel) {
            return false
        }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
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
        if controller.tool == .polygon, controller.isPolygonInProgress {
            switch event.keyCode {
            case 36:
                _ = controller.commitPolygon()
                return true
            case 53:
                controller.cancelPolygon()
                return true
            default:
                break
            }
        }
        if modifiers == [.command, .option],
           let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "c":
                controller.copySelectedAnnotations()
                return true
            case "v":
                controller.pasteAnnotations()
                return true
            default:
                break
            }
        }
        if modifiers == [.command],
           let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "a":
                controller.selectAll()
                return true
            case "d":
                controller.duplicateSelected()
                return true
            default:
                break
            }
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            controller.deleteSelected()
            return true
        }
        if modifiers == [.command, .shift],
           let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "r":
                redact(.sensitiveText)
                return true
            case "f":
                redact(.faces)
                return true
            case "a":
                redact(.allText)
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
                Task { await self.copyToPasteboard() }
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

    // MARK: - Editable history document

    /// Called once the background history write finishes, or immediately when
    /// the editor was opened from an existing history entry.
    func attachHistoryEntry(_ id: UUID) {
        historyEntryID = id
        guard window != nil else { return }
        persistDocumentSnapshot()
    }

    /// Saves the crop and annotations next to the original history PNG. An
    /// untouched document removes any stale snapshot from an earlier session.
    private func persistDocumentSnapshot() {
        guard let historyEntryID else { return }
        let document = controller.document
        let store = history
        if document.hasEdits {
            let snapshot = document.snapshot
            Task.detached(priority: .utility) {
                try? await store.saveDocument(snapshot, for: historyEntryID)
            }
        } else {
            Task.detached(priority: .utility) {
                await store.removeDocument(for: historyEntryID)
            }
        }
    }

    // MARK: - Copy and save

    /// Renders on a background executor. The document is a value snapshot, so
    /// the render does not block the main thread while a 6K canvas is composited.
    private static func render(_ document: EditDocument) async -> ImageData? {
        await Task.detached(priority: .userInitiated) {
            guard let image = DocumentRenderer.render(document) else { return nil }
            return ImageData(image)
        }.value
    }

    private func renderedPayload() async -> ImageData? {
        await Self.render(controller.document)
    }

    /// Copy/save output: plain render plus optional beautify and watermark.
    /// Pins and drag-out intentionally use the plain render.
    private func exportPayload() async -> ImageData? {
        guard let payload = await renderedPayload() else { return nil }
        let appearance = settings.exportAppearance
        guard appearance.hasWork else { return payload }
        return await Task.detached(priority: .userInitiated) {
            guard let composed = ExportRenderer.apply(
                payload.cgImage,
                options: appearance
            ) else { return nil as ImageData? }
            return ImageData(composed)
        }.value
    }

    private func defaultFileName(format: ImageFormat) -> String {
        CaptureFileSaver.defaultFileName(
            format: format,
            template: settings.fileNameTemplate,
            metadata: metadata
        )
    }

    private var targetBytes: Int? {
        settings.targetFileSizeKB > 0 ? settings.targetFileSizeKB * 1024 : nil
    }

    private static func pngData(for payload: ImageData) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            ImageExporter.pngData(from: payload.cgImage)
        }.value
    }

    private static func write(
        _ payload: ImageData,
        to url: URL,
        format: ImageFormat,
        quality: Double,
        targetBytes: Int?
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try CaptureFileSaver.write(
                payload.cgImage,
                to: url,
                format: format,
                quality: quality,
                targetBytes: targetBytes
            )
        }.value
    }

    private static func write(
        _ payload: ImageData,
        format: ImageFormat,
        quality: Double,
        directory: String,
        targetBytes: Int?,
        template: String,
        metadata: CaptureMetadata?
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try CaptureFileSaver.write(
                payload.cgImage,
                format: format,
                quality: quality,
                directory: directory,
                targetBytes: targetBytes,
                template: template,
                metadata: metadata
            )
        }.value
    }

    private func beginExport() -> Bool {
        guard !exportInFlight else {
            NSSound.beep()
            return false
        }
        exportInFlight = true
        return true
    }

    private func finishExport() {
        exportInFlight = false
    }

    /// Pins the rendered image as a floating window and closes the editor.
    /// Pins are not recorded to history.
    func pinAction() {
        guard beginExport() else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.finishExport() }
            self.commitPendingText()
            guard let payload = await self.renderedPayload() else { return }
            PinBoard.shared.pin(payload.cgImage)
            self.close()
        }
    }

    /// Esc closes the editor, optionally copying and/or saving the rendered
    /// image first (Shottr's "Action when hiding with Esc").
    private func escapeAction() {
        guard beginExport() else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.finishExport() }
            self.commitPendingText()
            let settings = self.settings
            if settings.copyOnEditorEscape {
                _ = await self.performCopy()
            }
            if settings.saveOnEditorEscape {
                await self.performSaveSilently(settings: settings)
            }
            self.close()
        }
    }

    /// Writes the rendered document to the configured save directory without
    /// any panel or close side effect; used by the Esc-save option.
    private func performSaveSilently(settings: AppSettings) async {
        guard let payload = await exportPayload() else { return }
        do {
            try await Self.write(
                payload,
                format: settings.format,
                quality: settings.jpegQuality,
                directory: settings.saveDirectory,
                targetBytes: targetBytes,
                template: settings.fileNameTemplate,
                metadata: metadata
            )
        } catch {
            NSSound.beep()
            NSLog("Snipbo: Esc-save failed: \(error.localizedDescription)")
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
    func copyToPasteboard() async -> Bool {
        guard beginExport() else { return false }
        defer { finishExport() }
        commitPendingText()
        return await performCopy()
    }

    private func performCopy() async -> Bool {
        // Encode before touching the pasteboard, so a render/encode failure
        // leaves the user's current clipboard contents intact.
        guard let payload = await exportPayload(),
              let data = await Self.pngData(for: payload) else {
            reportCopyFailure()
            return false
        }
        guard PasteboardWriter.writePNG(data, to: pasteboard) else {
            // The helper already put the previous contents back before
            // telling the user the copy failed.
            reportCopyFailure()
            return false
        }
        // No history record here: the capture was recorded on delivery, and
        // re-recording the rendered copy would duplicate the entry. The
        // editable snapshot is refreshed so re-opening sees these annotations.
        persistDocumentSnapshot()
        return true
    }

    private func reportCopyFailure() {
        NSLog("Snipbo: failed to copy the rendered screenshot to the pasteboard")
        NSSound.beep()
        guard let window, window.isVisible else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("Copy failed", "复制失败")
        alert.informativeText = L10n.tr(
            "The screenshot could not be placed on the clipboard.",
            "无法把截图放入剪贴板。"
        )
        alert.runModal()
    }

    /// Copies the rendered document and closes the editor. Enter, the toolbar
    /// Copy button, and any other "copy and finish" action use this; Cmd+C uses
    /// `copyToPasteboard()` and keeps the editor open.
    func copyAndClose() {
        guard beginExport() else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.finishExport() }
            self.commitPendingText()
            if await self.performCopy() {
                self.close()
            }
        }
    }

    private func saveAndClose(saveAs: Bool) {
        guard beginExport() else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.finishExport() }
            self.commitPendingText()
            // Snapshot the live settings once so the file name, directory,
            // format, and quality all come from the same action-time values.
            let settings = self.settings
            if saveAs {
                let fileName = self.defaultFileName(format: settings.format)
                let panel = self.savePanel(fileName: fileName)
                guard panel.runModal() == .OK, let selected = panel.url else { return }
                guard let payload = await self.exportPayload() else { return }
                do {
                    try await Self.write(
                        payload,
                        to: selected,
                        format: settings.format,
                        quality: settings.jpegQuality,
                        targetBytes: self.targetBytes
                    )
                    self.close()
                } catch {
                    NSAlert(error: error).runModal()
                }
            } else {
                guard let payload = await self.exportPayload() else { return }
                do {
                    try await Self.write(
                        payload,
                        format: settings.format,
                        quality: settings.jpegQuality,
                        directory: settings.saveDirectory,
                        targetBytes: self.targetBytes,
                        template: settings.fileNameTemplate,
                        metadata: self.metadata
                    )
                    self.close()
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    /// Builds the Save As panel for the configured output format. Split out so
    /// the panel configuration can be inspected without running it modally.
    func savePanel(fileName: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        switch settings.format {
        case .png:
            panel.allowedContentTypes = [.png]
        case .jpeg:
            panel.allowedContentTypes = [.jpeg]
        case .heic:
            panel.allowedContentTypes = [.heic]
        case .avif:
            panel.allowedContentTypes = [UTType("public.avif") ?? .heic]
        }
        return panel
    }

    // MARK: - Privacy redaction

    /// Runs on-device Vision detection on the unannotated crop and adds one
    /// pixelate annotation per result. Undo removes the whole batch at once.
    private func redact(_ mode: RedactionMode) {
        guard redactionTask == nil else { return }
        commitPendingText()
        var detectionDocument = controller.document
        // Existing annotations may contain text; recognize the source image
        // only so the editor never redacts its own labels.
        detectionDocument.annotations = []
        let cropRect = detectionDocument.cropRect
        let languages = settings.ocrLanguages
        redactionGeneration += 1
        let generation = redactionGeneration
        toolbarView?.setRedacting(true)

        redactionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.redactionGeneration {
                    self.redactionTask = nil
                    self.toolbarView?.setRedacting(false)
                }
            }
            guard let payload = await Self.render(detectionDocument) else {
                self.showRedactionMessage(
                    L10n.tr("The image could not be rendered.", "图像渲染失败。")
                )
                return
            }
            do {
                let regions = try await RedactionService.shared.regions(
                    in: payload,
                    mode: mode,
                    languages: languages
                )
                try Task.checkCancellation()
                guard generation == self.redactionGeneration else { return }
                guard self.controller.document.cropRect == cropRect else {
                    self.showRedactionMessage(L10n.tr(
                        "The image changed; run redaction again.",
                        "图像已变化，请重新打码。"
                    ))
                    return
                }
                guard !regions.isEmpty else {
                    NSSound.beep()
                    self.showRedactionMessage(L10n.tr(
                        "Nothing was found to redact.",
                        "未检测到需要打码的内容。"
                    ))
                    return
                }
                let mapped = regions.map {
                    $0.offsetBy(dx: cropRect.minX, dy: cropRect.minY)
                }
                self.controller.addRedactions(mapped)
            } catch is CancellationError {
                return
            } catch {
                self.showRedactionMessage(error.localizedDescription)
            }
        }
    }

    private func showRedactionMessage(_ message: String) {
        guard let window, window.isVisible else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.tr("Privacy Redaction", "隐私打码")
        alert.informativeText = message
        alert.runModal()
    }

    private func cancelRedaction() {
        redactionGeneration += 1
        redactionTask?.cancel()
        redactionTask = nil
        toolbarView?.setRedacting(false)
    }

    // MARK: - Recognition

    private func recognize() {
        guard recognitionTask == nil else { return }
        commitPendingText()
        let document = controller.document
        let cropRect = document.cropRect
        let languages = settings.ocrLanguages
        let removeLineBreaks = settings.ocrRemoveLineBreaks
        recognitionGeneration += 1
        let generation = recognitionGeneration

        setRecognitionPanelVisible(true)
        recognitionPanel.showProgress()
        toolbarView?.setRecognizing(true)
        canvas.setRecognitionHighlights([])

        recognitionTask = Task { [weak self] in
            guard let self else { return }
            guard let payload = await Self.render(document) else {
                self.finishRecognition(generation: generation)
                self.recognitionPanel.showMessage(
                    L10n.tr("The image could not be rendered.", "图像渲染失败。")
                )
                return
            }
            do {
                try Task.checkCancellation()
                let result = try await self.recognitionService.recognize(
                    payload,
                    languages: languages
                )
                try Task.checkCancellation()
                guard generation == self.recognitionGeneration else { return }
                // A crop or resize while Vision was running makes the boxes
                // relative to a different image; discard them instead of
                // drawing highlights in the wrong place.
                guard self.controller.document.cropRect == cropRect else {
                    self.finishRecognition(generation: generation)
                    self.recognitionPanel.showMessage(
                        L10n.tr("The image changed; run recognition again.", "图像已变化，请重新识别。")
                    )
                    return
                }
                self.finishRecognition(generation: generation)

                if result.isEmpty {
                    self.recognitionPanel.showMessage(L10n.tr("No text or barcode found.", "未识别到文字或条码。"))
                    NSSound.beep()
                    return
                }

                self.recognitionPanel.show(result, removeLineBreaks: removeLineBreaks)
                // Vision boxes are relative to the rendered crop; the canvas
                // works in original-image coordinates.
                let origin = cropRect.origin
                let textRects = result.textBlocks.map {
                    $0.pixelRect(
                        imageWidth: payload.cgImage.width,
                        imageHeight: payload.cgImage.height
                    )
                    .offsetBy(dx: origin.x, dy: origin.y)
                }
                let barcodeRects = result.barcodes.map {
                    $0.pixelRect(
                        imageWidth: payload.cgImage.width,
                        imageHeight: payload.cgImage.height
                    )
                    .offsetBy(dx: origin.x, dy: origin.y)
                }
                self.canvas.setRecognitionHighlights(textRects + barcodeRects)
            } catch is CancellationError {
                guard generation == self.recognitionGeneration else { return }
                self.finishRecognition(generation: generation)
            } catch {
                guard generation == self.recognitionGeneration else { return }
                self.finishRecognition(generation: generation)
                self.recognitionPanel.showMessage(error.localizedDescription)
                NSSound.beep()
            }
        }
    }

    private func finishRecognition(generation: Int) {
        guard generation == recognitionGeneration else { return }
        recognitionTask = nil
        toolbarView?.setRecognizing(false)
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
                recognitionPanel.topAnchor.constraint(equalTo: scrollView.topAnchor),
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
        snapshotSaveTask?.cancel()
        snapshotSaveTask = nil
        persistDocumentSnapshot()
        cancelRecognition()
        cancelRedaction()
        removeKeyMonitor()
        super.close()
    }

    func windowWillClose(_ notification: Notification) {
        commitPendingText()
        snapshotSaveTask?.cancel()
        snapshotSaveTask = nil
        persistDocumentSnapshot()
        cancelRecognition()
        cancelRedaction()
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
