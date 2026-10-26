import AppKit
import ImageIO
import SnipboCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var hotkeyService: HotkeyService?
    private let settingsModel = SettingsModel()
    private var settings: AppSettings { settingsModel.settings }
    private var settingsWindowController: SettingsWindowController?
    private var localShortcutMonitor: Any?
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
        L10n.setLanguage(settings.uiLanguage)
        let coordinator = captureCoordinator
        let recentController = recentMenuController
        statusItemController = StatusItemController(
            onCapture: { command in coordinator.start(command) },
            onSettings: { [weak self] in self?.showSettings() },
            onHistoryBrowser: { [weak self] in self?.showHistoryBrowser() },
            hotkeyFor: { [weak self] mode in self?.settings.hotkey(for: mode) },
            recentMenu: recentController.menu,
            lastRegionAvailable: { coordinator.canCaptureLastRegion() },
            onQuit: { NSApp.terminate(nil) }
        )
        statusItemController?.setIconHidden(settings.hideMenuBarIcon)
        var handlers: [UInt32: @MainActor () -> Void] = [:]
        for mode in AppSettings.hotkeyModeIDs {
            guard let carbonID = AppSettings.hotkeyModeIDsToCarbonID[mode],
                  let command = Self.command(for: mode) else { continue }
            handlers[carbonID] = { coordinator.start(command) }
        }
        let service = HotkeyService(handlers: handlers)
        hotkeyService = service
        applyModeHotkeys(settings)

        // The status-menu key equivalents only fire while that menu is open,
        // the capture overlay is a screen-saver-level window, and the app has
        // no main menu to route ⌘Q. Handle both chords locally whenever Snipbo
        // is frontmost instead of registering global chords that would steal
        // them from other apps.
        localShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleLocalShortcut(event) ? nil : event
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(historyWriteFailed(_:)),
            name: .snipboHistoryWriteFailed,
            object: nil
        )

        syncLoginItem(settings)
        appliedLanguage = settings.uiLanguage
        appliedHistoryMaxItems = settings.historyMaxItems
        appliedHistoryMaxBytes = settings.historyMaxBytes
        settingsModel.onChange = { [weak self] newSettings in
            guard let self else { return }
            self.applyModeHotkeys(newSettings)
            self.syncLoginItem(newSettings)
            L10n.setLanguage(newSettings.uiLanguage)
            if newSettings.uiLanguage != self.appliedLanguage {
                self.appliedLanguage = newSettings.uiLanguage
                // The menu shows localized titles and per-mode key equivalents;
                // rebuild it only when the language actually changed.
                self.statusItemController?.refreshLocalization()
            }
            self.statusItemController?.setIconHidden(newSettings.hideMenuBarIcon)
            self.captureCoordinator.updateSettings(newSettings)

            let limitsChanged = self.appliedHistoryMaxItems != newSettings.historyMaxItems
                || self.appliedHistoryMaxBytes != newSettings.historyMaxBytes
            guard limitsChanged else { return }
            self.appliedHistoryMaxItems = newSettings.historyMaxItems
            self.appliedHistoryMaxBytes = newSettings.historyMaxBytes
            Task {
                do {
                    try await self.historyStore.updateLimits(
                        maxItems: newSettings.historyMaxItems,
                        maxBytes: newSettings.historyMaxBytes
                    )
                    // Pruning can remove entries that the Recent menu still has
                    // cached; tell it to reconcile with the store.
                    NotificationCenter.default.post(name: .snipboHistoryDidChange, object: nil)
                } catch {
                    HistoryRecorder.logger.error(
                        "The history limits could not be applied: \(error.localizedDescription, privacy: .public)"
                    )
                    NotificationCenter.default.post(
                        name: .snipboHistoryWriteFailed,
                        object: L10n.tr(
                            "The history limits could not be applied.",
                            "历史记录上限未能应用。"
                        )
                    )
                }
            }
        }
    }

    private var registeredModeHotkeys: [String: Hotkey] = [:]

    private static func localizedModeName(_ mode: String) -> String {
        switch mode {
        case "region": return L10n.tr("Region", "区域")
        case "window": return L10n.tr("Window", "窗口")
        case "screen": return L10n.tr("Screen", "屏幕")
        case "allScreens": return L10n.tr("All screens", "全部屏幕")
        case "timedRegion": return L10n.tr("Timed region", "延时区域")
        case "timedScreen": return L10n.tr("Timed screen", "延时屏幕")
        case "lastRegion": return L10n.tr("Last region", "上次区域")
        case "scrolling": return L10n.tr("Scrolling", "滚动")
        default: return mode
        }
    }

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
                    failures.append("\(Self.localizedModeName(mode)) \(desired.displayString)")
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
        alert.messageText = L10n.tr("Global shortcut not registered", "全局快捷键未注册")
        alert.informativeText = L10n.tr(
            "Snipbo could not register: \(failures.joined(separator: ", ")). Other shortcuts remain active; choose different chords in Settings.",
            "Snipbo 无法注册：\(failures.joined(separator: "，"))。其他快捷键仍然有效，请在设置中更换组合。"
        )
        alert.runModal()
    }

    private var appliedLoginItem: Bool?
    private var appliedLanguage: AppLanguage?
    private var appliedHistoryMaxItems: Int?
    private var appliedHistoryMaxBytes: Int64?

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
            ?? L10n.tr(
                "The last screenshot could not be added to history.",
                "上一张截图未能加入历史。"
            )
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("Screenshot not added to history", "截图未加入历史")
        alert.informativeText = detail
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if settings.clearHistoryOnQuit {
            // Termination is synchronous; give the actor a bounded window to
            // delete the files before the process exits.
            let store = historyStore
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached(priority: .userInitiated) {
                try? await store.clear()
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 2)
        }
        if let localShortcutMonitor {
            NSEvent.removeMonitor(localShortcutMonitor)
            self.localShortcutMonitor = nil
        }
        hotkeyService?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// With the menu bar icon hidden there is no Dock icon to click, so
    /// reopening Snipbo from Spotlight or Finder must lead back to Settings
    /// (where the icon can be shown again).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showSettings()
        }
        return true
    }

    private func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(model: settingsModel)
        }
        settingsWindowController?.show()
    }

    /// Handles ⌘Q and ⌘, while Snipbo is frontmost. For ⌘, capture must be
    /// cancelled first: its overlay sits above normal windows. While Settings
    /// itself is key, ⌘, is left alone so the hotkey recorder can capture it
    /// as a chord; ⌘Q still quits.
    private func handleLocalShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let modifiers = hotkeyModifiers(from: flags)
        let keyCode = UInt32(event.keyCode)
        if QuitShortcut.matches(keyCode: keyCode, modifiers: modifiers) {
            NSApp.terminate(nil)
            return true
        }
        if settingsWindowController?.window?.isKeyWindow == true { return false }
        guard SettingsShortcut.matches(keyCode: keyCode, modifiers: modifiers) else { return false }
        captureCoordinator.cancelActiveCapture()
        showSettings()
        return true
    }

    private func hotkeyModifiers(from flags: NSEvent.ModifierFlags) -> HotkeyModifiers {
        var result: HotkeyModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }

    private var historyBrowserController: HistoryBrowserWindowController?

    private func showHistoryBrowser() {
        if historyBrowserController == nil {
            historyBrowserController = HistoryBrowserWindowController(
                store: historyStore,
                openInEditor: { [weak self] entry in self?.openHistoryEntry(entry) }
            )
        }
        historyBrowserController?.show()
    }

    /// Opens a stored screenshot in a new editor. The PNG is decoded off the
    /// menu action's synchronous path; if the file was deleted in the meantime
    /// the action is ignored instead of crashing.
    private func openHistoryEntry(_ entry: HistoryEntry) {
        Task { [weak self] in
            guard let self else { return }
            let url = await self.historyStore.imageURL(for: entry)
            let payload = await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    return nil as ImageData?
                }
                return ImageData(image)
            }.value
            guard let payload else {
                NSLog("Snipbo: could not open the recent screenshot at %@", url.path)
                return
            }
            let identifier = UUID()
            let editor = EditorWindowController(
                document: EditDocument(image: payload.cgImage),
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
