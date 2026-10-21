import AppKit
import LightShotCore

@MainActor
final class CaptureCoordinator {
    private let captureService: ScreenCaptureService
    private var settings: AppSettings
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
            defer { isCapturing = false }
            do {
                let captures = try await captureService.captureAllDisplays(includeCursor: settings.captureCursor)
                let alert = NSAlert()
                alert.messageText = "Captured \(captures.count) display(s)"
                alert.runModal()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private func ensurePermission() -> Bool {
        if PermissionService.hasScreenCaptureAccess { return true }
        if PermissionService.requestScreenCaptureAccess() { return true }
        PermissionService.openScreenRecordingSettings()
        return false
    }
}
