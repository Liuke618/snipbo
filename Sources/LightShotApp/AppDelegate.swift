import AppKit
import LightShotCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var hotkeyService: HotkeyService?
    private let settingsModel = SettingsModel()
    private var settings: AppSettings { settingsModel.settings }
    private var settingsWindowController: SettingsWindowController?
    private var registeredHotkey: Hotkey?
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
            onSettings: { [weak self] in self?.showSettings() },
            onQuit: { NSApp.terminate(nil) }
        )
        let service = HotkeyService { coordinator.startRegionCapture() }
        hotkeyService = service
        service.register(settings.hotkey)
        registeredHotkey = settings.hotkey

        settingsModel.onChange = { [weak self] newSettings in
            guard let self else { return }
            if newSettings.hotkey != self.registeredHotkey {
                self.registeredHotkey = newSettings.hotkey
                self.hotkeyService?.register(newSettings.hotkey)
            }
            self.captureCoordinator.updateSettings(newSettings)
            Task {
                try? await self.historyStore.updateLimits(
                    maxItems: newSettings.historyMaxItems,
                    maxBytes: newSettings.historyMaxBytes
                )
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyService?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(model: settingsModel)
        }
        settingsWindowController?.show()
    }
}
