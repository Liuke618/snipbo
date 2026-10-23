import AppKit
import LightShotCore
import os

@MainActor
final class CaptureCoordinator {
    private let captureService: ScreenCaptureService
    private var settings: AppSettings
    private let history: HistoryStore
    private let pasteboardProvider: () -> any PasteboardWriting
    private var overlays: [NSWindow] = []
    private var keyMonitor: Any?
    private var activeView: SelectionOverlayView?
    private var activePicker: WindowPickerView?
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

    func start(_ command: CaptureCommand) {
        switch command {
        case .region:
            startRegionCapture()
        case .window:
            startWindowCapture()
        }
    }

    func startRegionCapture() {
        guard beginCapture() else { return }
        Task {
            do {
                let captures = try await captureService.captureAllDisplays(
                    includeCursor: settings.captureCursor
                )
                present(captures: captures)
            } catch {
                fail(error)
            }
        }
    }

    func startWindowCapture() {
        guard beginCapture() else { return }
        Task {
            do {
                let targets = try await captureService.windowInventory()
                presentWindowPicker(targets)
            } catch {
                fail(error)
            }
        }
    }

    private func beginCapture() -> Bool {
        guard !isCapturing else { return false }
        guard ensurePermission() else { return false }
        isCapturing = true
        return true
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
        installKeyMonitor()

        if let first = overlays.first {
            first.makeKeyAndOrderFront(nil)
        }
    }

    private func presentWindowPicker(_ targets: [WindowTarget]) {
        let layout = ScreenLayout.current()
        NSApp.activate(ignoringOtherApps: true)
        overlays.removeAll()
        activePicker = nil

        for screen in layout.screens {
            let bounds = CGRect(origin: .zero, size: screen.frame.size)
            let screenTargets: [WindowPickerView.Target] = targets.compactMap { target in
                let rect = layout.localRect(fromCGRect: target.frame, on: screen)
                guard rect.intersects(bounds) else { return nil }
                return WindowPickerView.Target(window: target, rect: rect)
            }
            // Cover every screen, even one with no targets, so clicks cannot
            // reach the desktop while the picker is active.
            let window = SelectionOverlayWindow(screenFrame: screen.frame)
            let view = WindowPickerView(screenFrame: screen.frame, targets: screenTargets)
            view.onPick = { [weak self] target in
                self?.capture(window: target)
            }
            view.onCancel = { [weak self] in
                self?.dismiss()
            }
            window.contentView = view
            window.makeFirstResponder(view)
            window.orderFrontRegardless()
            overlays.append(window)
            if activePicker == nil {
                activePicker = view
            }
        }

        guard !overlays.isEmpty else {
            fail(CaptureError.noWindows)
            return
        }
        installKeyMonitor()
        overlays.first?.makeKeyAndOrderFront(nil)
    }

    private func installKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if let active = self.activeView {
                return active.handleKey(event) ? nil : event
            }
            if let picker = self.activePicker {
                return picker.handleKey(event) ? nil : event
            }
            return event
        }
    }

    private func capture(window target: WindowTarget) {
        dismiss()
        isCapturing = true
        Task {
            do {
                let capture = try await captureService.captureWindow(
                    windowID: target.windowID,
                    includeCursor: settings.captureCursor
                )
                isCapturing = false
                deliver(capture.image, source: .window)
            } catch {
                fail(error)
            }
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
        deliver(cropped, source: .region)
    }

    /// Opens the editor or copies directly according to the live setting. The
    /// delivery path is shared by every capture mode so history sources and
    /// failure handling cannot drift.
    private func deliver(_ image: CGImage, source: CaptureSource) {
        if settings.openEditorAfterCapture {
            let identifier = UUID()
            let editor = EditorWindowController(
                document: EditDocument(image: image),
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

        guard let data = ImageExporter.pngData(from: image) else {
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
        HistoryRecorder.record(image, source: source, settings: settings, history: history)
    }

    private func fail(_ error: Error) {
        dismiss()
        NSAlert(error: error).runModal()
    }

    private func dismiss() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        activeView = nil
        activePicker = nil
        isCapturing = false
    }

    private func ensurePermission() -> Bool {
        if PermissionService.hasScreenCaptureAccess { return true }
        if PermissionService.requestScreenCaptureAccess() { return true }
        PermissionService.openScreenRecordingSettings()
        return false
    }
}
