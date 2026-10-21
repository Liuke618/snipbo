import AppKit
import LightShotCore

@MainActor
final class CaptureCoordinator {
    private let captureService: ScreenCaptureService
    private var settings: AppSettings
    private var overlays: [SelectionOverlayWindow] = []
    private var keyMonitor: Any?
    private var activeView: SelectionOverlayView?
    private var isCapturing = false

    init(captureService: ScreenCaptureService, settings: AppSettings) {
        self.captureService = captureService
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
        defer { dismiss() }
        guard let cropped = capture.cropped(toLocalPoints: rect),
              let data = ImageExporter.pngData(from: cropped) else {
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
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
