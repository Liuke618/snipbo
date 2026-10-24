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
    private lazy var lastRegionStore = LastRegionStore()
    private lazy var captureCoordinator = CaptureCoordinator(
        captureService: captureService,
        settings: settings,
        history: historyStore,
        lastRegion: lastRegionStore
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = captureCoordinator
        let recentController = recentMenuController
        statusItemController = StatusItemController(
            onCapture: { command in coordinator.start(command) },
            onSettings: { [weak self] in self?.showSettings() },
            recentMenu: recentController.menu,
            lastRegionAvailable: { coordinator.canCaptureLastRegion() },
            onQuit: { NSApp.terminate(nil) }
        )
        var handlers: [UInt32: @MainActor () -> Void] = [:]
        for mode in AppSettings.hotkeyModeIDs {
            guard let carbonID = AppSettings.hotkeyModeIDsToCarbonID[mode],
                  let command = Self.command(for: mode) else { continue }
            handlers[carbonID] = { coordinator.start(command) }
        }
        let service = HotkeyService(handlers: handlers)
        hotkeyService = service
        applyModeHotkeys(settings)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(historyWriteFailed(_:)),
            name: .lightShotHistoryWriteFailed,
            object: nil
        )

        syncLoginItem(settings)
        settingsModel.onChange = { [weak self] newSettings in
            guard let self else { return }
            self.applyModeHotkeys(newSettings)
            self.syncLoginItem(newSettings)
            self.captureCoordinator.updateSettings(newSettings)
            Task {
                do {
                    try await self.historyStore.updateLimits(
                        maxItems: newSettings.historyMaxItems,
                        maxBytes: newSettings.historyMaxBytes
                    )
                    // Pruning can remove entries that the Recent menu still has
                    // cached; tell it to reconcile with the store.
                    NotificationCenter.default.post(name: .lightShotHistoryDidChange, object: nil)
                } catch {
                    let message = "The history limits could not be applied: \(error.localizedDescription)"
                    HistoryRecorder.logger.error("\(message, privacy: .public)")
                    NotificationCenter.default.post(name: .lightShotHistoryWriteFailed, object: message)
                }
            }
        }
    }

    private var registeredModeHotkeys: [String: Hotkey] = [:]

    private static func command(for mode: String) -> CaptureCommand? {
        switch mode {
        case "region": return .region
        case "window": return .window
        case "screen": return .screen
        case "allScreens": return .allScreens
        case "timedRegion": return .timedRegion
        case "timedScreen": return .timedScreen
        case "lastRegion": return .lastRegion
        case "scrolling": return .scrolling
        default: return nil
        }
    }

    /// Registers every mode chord transactionally: a mode whose new chord is
    /// rejected keeps its previous chord, removed chords are unregistered, and
    /// the user is alerted when anything could not be applied.
    private func applyModeHotkeys(_ settings: AppSettings) {
        guard let hotkeyService else { return }
        var failures: [String] = []
        var applied: [String: Hotkey] = [:]
        for mode in AppSettings.hotkeyModeIDs {
            let desired = settings.hotkey(for: mode)
            let registered = registeredModeHotkeys[mode]
            if desired == registered {
                if let desired { applied[mode] = desired }
                continue
            }
            let id = AppSettings.hotkeyModeIDsToCarbonID[mode] ?? 0
            if let desired {
                if hotkeyService.register(desired, id: id) {
                    applied[mode] = desired
                } else {
                    // register(id:) unregisters before trying, so restore the
                    // previous chord when there was one.
                    if let registered, hotkeyService.register(registered, id: id) {
                        applied[mode] = registered
                    }
                    failures.append("\(mode) \(desired.displayString)")
                }
            } else {
                hotkeyService.unregister(id: id)
            }
        }
        registeredModeHotkeys = applied
        guard !failures.isEmpty else { return }
        HistoryRecorder.logger.error(
            "Hotkey registration failed for: \(failures.joined(separator: ", "), privacy: .public)"
        )
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Global shortcut not registered"
        alert.informativeText = "LightShot could not register: \(failures.joined(separator: ", ")). Other shortcuts remain active; choose different chords in Settings."
        alert.runModal()
    }

    private var appliedLoginItem: Bool?

    /// Applies launch-at-login only when the desired state changes, so a
    /// Settings window left open cannot re-register on every keystroke.
    private func syncLoginItem(_ settings: AppSettings) {
        guard appliedLoginItem != settings.launchAtLogin else { return }
        appliedLoginItem = settings.launchAtLogin
        LoginItemService.sync(enabled: settings.launchAtLogin)
    }

    /// Shows a history failure without interrupting the copy or save that has
    /// already completed. A sheet is used when a window can host it; otherwise
    /// the alert is shown after the failed background write, when nothing else
    /// is waiting on the main thread.
    @objc private func historyWriteFailed(_ notification: Notification) {
        let detail = (notification.object as? String)
            ?? "The last screenshot could not be added to history."
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Screenshot not added to history"
        alert.informativeText = detail
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
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
                settingsProvider: { [weak self] in self?.settings ?? .default },
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
