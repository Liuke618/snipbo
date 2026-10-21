import AppKit
import LightShotCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var hotkeyService: HotkeyService?
    private let settings = AppSettings.default
    private let captureService = ScreenCaptureService()
    private lazy var historyStore = HistoryStore(
        baseDirectory: AppPaths.historyDirectory,
        maxItems: settings.historyMaxItems,
        maxBytes: settings.historyMaxBytes
    )
    private lazy var captureCoordinator = CaptureCoordinator(
        captureService: captureService,
        settings: settings,
        history: historyStore
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = captureCoordinator
        statusItemController = StatusItemController(
            onCaptureRegion: { coordinator.startRegionCapture() },
            onQuit: { NSApp.terminate(nil) }
        )
        hotkeyService = HotkeyService { coordinator.startRegionCapture() }
        hotkeyService?.register(settings.hotkey)
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyService?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
