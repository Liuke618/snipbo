import AppKit
import LightShotCore

@MainActor
final class CaptureCoordinator {
    private let captureService: ScreenCaptureService
    private var settings: AppSettings
    private let history: HistoryStore
    private var overlays: [SelectionOverlayWindow] = []
    private var keyMonitor: Any?
    private var activeView: SelectionOverlayView?
    private var isCapturing = false
    private var editorWindow: EditorWindowController?

    init(captureService: ScreenCaptureService, settings: AppSettings, history: HistoryStore) {
        self.captureService = captureService
        self.settings = settings
        self.history = history
    }

    /// Applies settings changed in the Settings window. Captures and editors
    /// that are already on screen keep the settings they were opened with;
    /// the next capture/editor uses the new values.
    func updateSettings(_ settings: AppSettings) {
        self.settings = settings
    }

    func startRegionCapture() {
        guard !isCapturing else { return }
        guard ensurePermission() else { return }
        isCapturing = true
        Task {
            do {
                let captures = try await captureService.captureAllDisplays(includeCursor: settings.captureCursor)
                present(captures: captures)
            } catch {
                isCapturing = false
                NSAlert(error: error).runModal()
            }
        }
    }

    private func present(captures: [CapturedImage]) {
        NSApp.activate(ignoringOtherApps: true)
        overlays = captures.map { capture in
            let window = SelectionOverlayWindow(screenFrame: capture.geometry.frame)
            let view = SelectionOverlayView(captured: capture)
            view.onConfirm = { [weak self] rect in
                self?.finish(capture: capture, rect: rect)
            }
            view.onCancel = { [weak self] in
                self?.dismiss()
            }
            view.onHover = { [weak self, weak view] in
                self?.activeView = view
            }
            window.contentView = view
            window.makeFirstResponder(view)
            window.orderFrontRegardless()
            return window
        }

        activeView = overlays.first?.contentView as? SelectionOverlayView

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let active = self.activeView else { return event }
            return active.handleKey(event) ? nil : event
        }

        if let first = overlays.first {
            first.makeKeyAndOrderFront(nil)
        }
    }

    private func finish(capture: CapturedImage, rect: CGRect) {
        guard let cropped = capture.cropped(toLocalPoints: rect) else {
            dismiss()
            NSSound.beep()
            return
        }
        dismiss()

        if settings.openEditorAfterCapture {
            let editor = EditorWindowController(
                document: EditDocument(image: cropped),
                settings: settings,
                history: history,
                onClose: { [weak self] in self?.editorWindow = nil }
            )
            editorWindow = editor
            editor.show()
            return
        }

        guard let data = ImageExporter.pngData(from: cropped) else {
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        HistoryRecorder.record(cropped, source: .region, settings: settings, history: history)
    }

    private func dismiss() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        activeView = nil
        isCapturing = false
    }

    private func ensurePermission() -> Bool {
        if PermissionService.hasScreenCaptureAccess { return true }
        if PermissionService.requestScreenCaptureAccess() { return true }
        PermissionService.openScreenRecordingSettings()
        return false
    }
}
