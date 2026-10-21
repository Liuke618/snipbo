import AppKit
import LightShotCore
import os

@MainActor
final class CaptureCoordinator {
    private let captureService: ScreenCaptureService
    private var settings: AppSettings
    private let history: HistoryStore
    private let pasteboardProvider: () -> any PasteboardWriting
    private var overlays: [SelectionOverlayWindow] = []
    private var keyMonitor: Any?
    private var activeView: SelectionOverlayView?
    private var isCapturing = false
    /// Every open capture editor, retained until its own close callback runs.
    /// The callback removes exactly the editor that closed, so a second
    /// capture can never deallocate (and disable) the first editor.
    private(set) var editors: [EditorWindowController] = []
    private let logger = Logger(subsystem: "local.lightshot.app", category: "Capture")

    init(
        captureService: ScreenCaptureService,
        settings: AppSettings,
        history: HistoryStore,
        pasteboardProvider: @escaping () -> any PasteboardWriting = { NSPasteboard.general }
    ) {
        self.captureService = captureService
        self.settings = settings
        self.history = history
        self.pasteboardProvider = pasteboardProvider
    }

    /// Applies settings changed in the Settings window. Captures use the new
    /// values immediately; open editors read them through their settings
    /// provider at copy/save time.
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
                self?.complete(capture: capture, rect: rect)
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

    /// Completes a confirmed selection. Internal so the committed harness can
    /// drive the editor and direct-copy paths without a real screen capture.
    func complete(capture: CapturedImage, rect: CGRect) {
        guard let cropped = capture.cropped(toLocalPoints: rect) else {
            dismiss()
            NSSound.beep()
            return
        }
        dismiss()

        if settings.openEditorAfterCapture {
            let identifier = UUID()
            let editor = EditorWindowController(
                document: EditDocument(image: cropped),
                settingsProvider: { [weak self] in self?.settings ?? .default },
                history: history,
                identifier: identifier,
                pasteboard: pasteboardProvider(),
                onClose: { [weak self] in
                    // Remove only the editor whose close callback runs; a
                    // late close must not drop a newer editor.
                    guard let self else { return }
                    self.editors.removeAll { $0.identifier == identifier }
                }
            )
            editors.append(editor)
            editor.show()
            return
        }

        guard let data = ImageExporter.pngData(from: cropped) else {
            NSSound.beep()
            return
        }
        // Encode before touching the pasteboard, then write with rollback so a
        // rejected write leaves the previous clipboard contents in place and
        // never records a screenshot that was not copied.
        guard PasteboardWriter.writePNG(data, to: pasteboardProvider()) else {
            logger.error("Failed to copy the captured screenshot to the pasteboard")
            NSSound.beep()
            return
        }
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
