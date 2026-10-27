import AppKit
import ImageIO
import SnipboCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var hotkeyService: HotkeyService?
    private let settingsModel = SettingsModel()
    private var settings: AppSettings { settingsModel.settings }
    private var appliedHiddenStatusItems: Set<StatusMenuItem> = []
    private var settingsWindowController: SettingsWindowController?
    private var localShortcutMonitor: Any?
    private let captureService = ScreenCaptureService()
    /// Every open history editor, retained until its own close callback runs.
    /// The close callback removes exactly the editor that closed, so one
    /// editor closing cannot drop another one.
    private var historyEditors: [EditorWindowController] = []
    /// URLs delivered by LaunchServices before the app finished launching.
    private var pendingURLs: [URL] = []
    private var didFinishLaunching = false
    private lazy var historyStore = HistoryStore(
        baseDirectory: AppPaths.historyDirectory,
        maxItems: settings.historyMaxItems,
        maxBytes: settings.historyMaxBytes
    )
    private lazy var recentMenuController = RecentMenuController(
        history: historyStore,
        openEntry: { [weak self] entry in self?.openHistoryEntry(entry) }
    )
    private lazy var pinsMenuController = PinsMenuController(
        pins: { PinBoard.shared.managedPins() },
        showPin: { PinBoard.shared.showPin(id: $0) },
        closePin: { PinBoard.shared.closePin(id: $0) },
        closeAll: { PinBoard.shared.closeAll() }
    )
    private lazy var regionPresetsController = RegionPresetsMenuController(
        store: lastRegionStore,
        capture: { [weak self] preset in
            self?.captureCoordinator.startPresetRegionCapture(preset)
        }
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
        applyAppearance(settings.appearance)
        ImageDragSupport.cleanup()
        PinBoard.shared.restore()
        let coordinator = captureCoordinator
        let recentController = recentMenuController
        let pinsController = pinsMenuController
        let presetsController = regionPresetsController
        statusItemController = StatusItemController(
            onCapture: { command in coordinator.start(command) },
            onSettings: { [weak self] in self?.showSettings() },
            onHistoryBrowser: { [weak self] in self?.showHistoryBrowser() },
            hotkeyFor: { [weak self] mode in self?.settings.hotkey(for: mode) },
            recentMenu: recentController.menu,
            pinsMenu: pinsController.menu,
            presetsMenu: presetsController.menu,
            lastRegionAvailable: { coordinator.canCaptureLastRegion() },
            onQuit: { NSApp.terminate(nil) },
            hiddenStatusItems: { [weak self] in self?.settings.hiddenStatusItems ?? [] }
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
        // no main menu to route ⌘Q, ⌘W or ⌘,. Handle these chords locally
        // whenever Snipbo is frontmost instead of registering global chords
        // that would steal them from other apps.
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
            self.applyAppearance(newSettings.appearance)
            if newSettings.uiLanguage != self.appliedLanguage {
                self.appliedLanguage = newSettings.uiLanguage
                // The menu shows localized titles and per-mode key equivalents;
                // rebuild it only when the language actually changed.
                self.statusItemController?.refreshLocalization()
            }
            if newSettings.hiddenStatusItems != self.appliedHiddenStatusItems {
                self.appliedHiddenStatusItems = newSettings.hiddenStatusItems
                // Settings owns this choice now, so rebuild the menu whenever it
                // changes instead of waiting for a language switch.
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

        didFinishLaunching = true
        let urls = pendingURLs
        pendingURLs.removeAll()
        for url in urls {
            handleURL(url)
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
        case "timedWindow": return L10n.tr("Timed window", "延时窗口")
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
        case "timedWindow": return .timedWindow
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
    private var appliedAppearance: AppAppearance?
    private var appliedHistoryMaxItems: Int?
    private var appliedHistoryMaxBytes: Int64?

    private func applyAppearance(_ appearance: AppAppearance) {
        guard appliedAppearance != appearance else { return }
        appliedAppearance = appearance
        switch appearance {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

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

    // MARK: - URL commands

    /// Supports `snipbo://capture?mode=region&action=copy`,
    /// `snipbo://settings`, and `snipbo://history`. Shortcuts, Raycast, and the
    /// bundled `snipbo` CLI all use these URLs.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard didFinishLaunching else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        for url in urls {
            handleURL(url)
        }
    }

    private func handleURL(_ url: URL) {
        guard url.scheme?.lowercased() == "snipbo" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let host = (url.host ?? "").lowercased()
        let query = Dictionary(
            (components?.queryItems ?? []).compactMap { item in
                item.value.map { (item.name.lowercased(), $0.lowercased()) }
            },
            uniquingKeysWith: { _, last in last }
        )

        switch host {
        case "capture", "":
            let mode = query["mode"] ?? "region"
            if mode == "record-stop" {
                captureCoordinator.stopRecordingForAutomation()
                return
            }
            if mode == "record-cancel" {
                captureCoordinator.cancelRecordingForAutomation()
                return
            }
            if mode == "app-windows" || mode == "appwindows" {
                captureCoordinator.startAppWindowsCapture(appName: query["app"])
                return
            }
            if mode == "record-region" || mode == "record-screen" {
                let format = query["format"].flatMap(RecordingFormat.init(rawValue:))
                if mode == "record-region" {
                    captureCoordinator.startRecordRegion(formatOverride: format)
                } else {
                    captureCoordinator.startRecordScreen(formatOverride: format)
                }
                return
            }
            guard let command = Self.command(forURLMode: mode) else {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L10n.tr("Unknown capture mode", "未知截图模式")
                alert.informativeText = mode
                alert.runModal()
                return
            }
            captureCoordinator.start(
                command,
                actionsOverride: Self.actions(from: query["action"])
            )
        case "history":
            showHistoryBrowser()
        case "settings", "preferences":
            showSettings()
        default:
            showSettings()
        }
    }

    private static func command(forURLMode mode: String) -> CaptureCommand? {
        switch mode {
        case "region": return .region
        case "window": return .window
        case "app-windows", "appwindows": return .appWindows
        case "screen": return .screen
        case "all", "allscreens", "all-screens": return .allScreens
        case "timed-region", "timedregion": return .timedRegion
        case "timed-screen", "timedscreen": return .timedScreen
        case "timed-window", "timedwindow": return .timedWindow
        case "last", "lastregion", "last-region": return .lastRegion
        case "scroll", "scrolling": return .scrolling
        case "scroll-horizontal", "scrollhorizontal": return .scrollingHorizontal
        case "scroll-auto", "scrollauto": return .scrollingAuto
        case "record-region", "recordregion": return .recordRegion
        case "record-screen", "recordscreen": return .recordScreen
        default: return nil
        }
    }

    private static func actions(from token: String?) -> CaptureActions? {
        guard let token, !token.isEmpty else { return nil }
        var actions = CaptureActions()
        for piece in token.split(separator: ",") {
            switch piece.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "editor", "edit": actions.openEditor = true
            case "copy": actions.copy = true
            case "save": actions.save = true
            case "pin": actions.pin = true
            default: break
            }
        }
        guard !actions.isEmpty else { return nil }
        return actions
    }

    private func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(model: settingsModel)
        }
        settingsWindowController?.show()
    }

    /// Handles ⌘Q, ⌘W and ⌘, while Snipbo is frontmost. For ⌘, capture must be
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
        if CloseWindowShortcut.matches(keyCode: keyCode, modifiers: modifiers) {
            // While a hotkey recorder is armed it owns the next chord, so ⌘W
            // has to stay bindable as a capture shortcut.
            if (NSApp.keyWindow?.firstResponder as? HotkeyRecorderNSView)?.isRecording == true {
                return false
            }
            return closeKeyWindow()
        }
        if settingsWindowController?.window?.isKeyWindow == true { return false }
        guard SettingsShortcut.matches(keyCode: keyCode, modifiers: modifiers) else { return false }
        captureCoordinator.cancelActiveCapture()
        showSettings()
        return true
    }

    /// Routes ⌘W to the focused window. The capture overlay and the floating
    /// controls are higher-level panels whose lifecycle the coordinator owns,
    /// so those keep Escape as their only dismissal.
    private func closeKeyWindow() -> Bool {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              window.level == .normal else { return false }
        window.performClose(nil)
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
            let snapshot = await self.historyStore.document(for: entry.id)
            var document = EditDocument(
                image: payload.cgImage,
                backingScale: snapshot?.backingScale ?? 1
            )
            if let snapshot {
                let bounds = CGRect(
                    x: 0,
                    y: 0,
                    width: payload.cgImage.width,
                    height: payload.cgImage.height
                )
                let crop = snapshot.cropRect.intersection(bounds).integral
                if crop.width >= 1, crop.height >= 1 {
                    document.cropRect = crop
                }
                document.annotations = snapshot.annotations
            }
            let identifier = UUID()
            let editor = EditorWindowController(
                document: document,
                settingsProvider: { [weak self] in self?.settings ?? .default },
                history: self.historyStore,
                identifier: identifier,
                historyEntryID: entry.id,
                onClose: { [weak self] in
                    self?.historyEditors.removeAll { $0.identifier == identifier }
                }
            )
            self.historyEditors.append(editor)
            editor.show()
        }
    }
}
