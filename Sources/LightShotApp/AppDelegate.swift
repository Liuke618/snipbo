import AppKit
import LightShotCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var hotkeyService: HotkeyService?
    private let settings = AppSettings.default
    private let captureService = ScreenCaptureService()
    private lazy var captureCoordinator = CaptureCoordinator(
        captureService: captureService,
        settings: settings
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = captureCoordinator
        statusItemController = StatusItemController(
            onCaptureRegion: { coordinator.startRegionCapture() },
            onCaptureTest: { [weak self] in self?.runCaptureTest() },
            onQuit: { NSApp.terminate(nil) }
        )
        hotkeyService = HotkeyService { coordinator.startRegionCapture() }
        hotkeyService?.register(settings.hotkey)
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyService?.unregister()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func runCaptureTest() {
        if !PermissionService.hasScreenCaptureAccess,
           !PermissionService.requestScreenCaptureAccess() {
            PermissionService.openScreenRecordingSettings()
            return
        }
        Task {
            do {
                let captures = try await captureService.captureAllDisplays(includeCursor: false)
                guard let first = captures.first,
                      let data = ImageExporter.pngData(from: first.image) else {
                    NSSound.beep()
                    return
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("lightshot-capture-\(UUID().uuidString).png")
                try data.write(to: url)
                NSWorkspace.shared.open(url)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}
