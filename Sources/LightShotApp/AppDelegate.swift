import AppKit
import ImageIO
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
    /// Every open history editor, retained until its own close callback runs.
    /// The close callback removes exactly the editor that closed, so one
    /// editor closing cannot drop another one.
    private var historyEditors: [EditorWindowController] = []
    private lazy var historyStore = HistoryStore(
        baseDirectory: AppPaths.historyDirectory,
        maxItems: settings.historyMaxItems,
        maxBytes: settings.historyMaxBytes
    )
    private lazy var recentMenuController = RecentMenuController(
        history: historyStore,
        openEntry: { [weak self] entry in self?.openHistoryEntry(entry) }
    )
    private lazy var captureCoordinator = CaptureCoordinator(
        captureService: captureService,
        settings: settings,
        history: historyStore
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = captureCoordinator
        let recentController = recentMenuController
        statusItemController = StatusItemController(
            onCaptureRegion: { coordinator.startRegionCapture() },
            onSettings: { [weak self] in self?.showSettings() },
            recentMenu: recentController.menu,
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

    /// Opens a stored screenshot in a new editor. The PNG is decoded off the
    /// menu action's synchronous path; if the file was deleted in the meantime
    /// the action is ignored instead of crashing.
    private func openHistoryEntry(_ entry: HistoryEntry) {
        Task { [weak self] in
            guard let self else { return }
            let url = await self.historyStore.imageURL(for: entry)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                NSLog("LightShot: could not open the recent screenshot at %@", url.path)
                return
            }
            let identifier = UUID()
            let editor = EditorWindowController(
                document: EditDocument(image: image),
                settings: self.settings,
                history: self.historyStore,
                identifier: identifier,
                onClose: { [weak self] in
                    self?.historyEditors.removeAll { $0.identifier == identifier }
                }
            )
            self.historyEditors.append(editor)
            editor.show()
        }
    }
}
