import AppKit
import LightShotCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private let captureService = ScreenCaptureService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(
            onCaptureTest: { [weak self] in self?.runCaptureTest() },
            onQuit: { NSApp.terminate(nil) }
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func runCaptureTest() {
        if !PermissionService.hasScreenCaptureAccess {
            guard PermissionService.requestScreenCaptureAccess() else {
                PermissionService.openScreenRecordingSettings()
                return
            }
        }
        Task {
            do {
                let captures = try await captureService.captureAllDisplays(includeCursor: false)
                guard let first = captures.first,
                      let data = ImageExporter.pngData(from: first.image) else {
                    NSSound.beep()
                    return
                }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("lightshot-capture-\(UUID().uuidString).png")
                try data.write(to: url)
                NSWorkspace.shared.open(url)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }
}
