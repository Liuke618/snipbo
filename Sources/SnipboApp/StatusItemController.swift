import AppKit
import SnipboCore

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let onCapture: (CaptureCommand) -> Void
    private let onSettings: () -> Void
    private let onHistoryBrowser: () -> Void
    private let hotkeyFor: (String) -> Hotkey?
    private let recentMenu: NSMenu
    private let pinsMenu: NSMenu
    private let presetsMenu: NSMenu
    private let lastRegionAvailable: () -> Bool
    private let onQuit: () -> Void
    private let hiddenStatusItems: () -> Set<StatusMenuItem>
    private var lastRegionItem: NSMenuItem?

    init(
        onCapture: @escaping (CaptureCommand) -> Void,
        onSettings: @escaping () -> Void,
        onHistoryBrowser: @escaping () -> Void,
        hotkeyFor: @escaping (String) -> Hotkey?,
        recentMenu: NSMenu,
        pinsMenu: NSMenu,
        presetsMenu: NSMenu,
        lastRegionAvailable: @escaping () -> Bool,
        onQuit: @escaping () -> Void,
        hiddenStatusItems: @escaping () -> Set<StatusMenuItem>
    ) {
        self.onCapture = onCapture
        self.onSettings = onSettings
        self.onHistoryBrowser = onHistoryBrowser
        self.hotkeyFor = hotkeyFor
        self.recentMenu = recentMenu
        self.pinsMenu = pinsMenu
        self.presetsMenu = presetsMenu
        self.lastRegionAvailable = lastRegionAvailable
        self.onQuit = onQuit
        self.hiddenStatusItems = hiddenStatusItems
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let icon = Self.icon("focus", size: 18) {
            statusItem.button?.image = icon
        } else {
            statusItem.button?.image = NSImage(
                systemSymbolName: "camera.viewfinder",
                accessibilityDescription: "Snipbo"
            )
        }
        statusItem.button?.toolTip = L10n.tr(
            "Snipbo — screenshots, OCR, pins",
            "Snipbo — 截图、OCR、贴图"
        )

        let menu = NSMenu()
        menu.delegate = self
        populateMenu(menu)
        statusItem.menu = menu
    }

    /// Hides or shows the menu bar icon without recreating the item, so the
    /// menu keeps its state while the user is in Settings.
    func setIconHidden(_ hidden: Bool) {
        statusItem.isVisible = !hidden
    }

    /// Rebuilds every item so a language or hotkey change takes effect the
    /// next time the menu opens.
    func refreshLocalization() {
        rebuildMenu()
        statusItem.button?.toolTip = L10n.tr(
            "Snipbo — screenshots, OCR, pins",
            "Snipbo — 截图、OCR、贴图"
        )
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        populateMenu(menu)
        statusItem.button?.toolTip = L10n.tr(
            "Snipbo — screenshots, OCR, pins",
            "Snipbo — 截图、OCR、贴图"
        )
    }

    /// Loads a bundled Lucide SVG as a monochrome template image. The icon
    /// files live in the app bundle's Resources/Icons (see build_app.sh).
    private static func icon(_ name: String, size: CGFloat) -> NSImage? {
        guard let url = Bundle.main.url(
            forResource: name,
            withExtension: "svg",
            subdirectory: "Icons"
        ), let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: size, height: size)
        return image
    }

    private func populateMenu(_ menu: NSMenu) {
        let regionItem = makeItem(StatusMenuItem.region.title, icon: "scan", action: #selector(captureRegion))
        applyKeyEquivalent(regionItem, mode: "region")
        add(regionItem, as: .region, to: menu)

        let windowItem = makeItem(StatusMenuItem.window.title, icon: "app-window", action: #selector(captureWindow))
        applyKeyEquivalent(windowItem, mode: "window")
        add(windowItem, as: .window, to: menu)
        menu.addItem(makeItem(
            StatusMenuItem.appWindows.title,
            icon: "layers",
            action: #selector(captureAppWindows)
        ))

        let screenItem = makeItem(StatusMenuItem.screen.title, icon: "monitor", action: #selector(captureScreen))
        applyKeyEquivalent(screenItem, mode: "screen")
        add(screenItem, as: .screen, to: menu)

        let allScreensItem = makeItem(StatusMenuItem.allScreens.title, icon: "layers", action: #selector(captureAllScreens))
        applyKeyEquivalent(allScreensItem, mode: "allScreens")
        add(allScreensItem, as: .allScreens, to: menu)

        let timedItem = NSMenuItem(title: StatusMenuItem.timed.title, action: nil, keyEquivalent: "")
        timedItem.image = Self.icon("timer", size: 16)
        let timedMenu = NSMenu()
        let timedRegionSub = makeItem(L10n.tr("Region", "区域"), action: #selector(captureTimedRegion))
        applyKeyEquivalent(timedRegionSub, mode: "timedRegion")
        timedMenu.addItem(timedRegionSub)
        let timedScreenSub = makeItem(L10n.tr("Screen", "屏幕"), action: #selector(captureTimedScreen))
        applyKeyEquivalent(timedScreenSub, mode: "timedScreen")
        timedMenu.addItem(timedScreenSub)
        let timedWindowSub = makeItem(L10n.tr("Window", "窗口"), action: #selector(captureTimedWindow))
        applyKeyEquivalent(timedWindowSub, mode: "timedWindow")
        timedMenu.addItem(timedWindowSub)
        timedItem.submenu = timedMenu
        add(timedItem, as: .timed, to: menu)

        let lastRegionItem = makeItem(StatusMenuItem.lastRegion.title, icon: "square-dashed", action: #selector(captureLastRegion))
        applyKeyEquivalent(lastRegionItem, mode: "lastRegion")
        self.lastRegionItem = lastRegionItem
        add(lastRegionItem, as: .lastRegion, to: menu)
        let presetsItem = NSMenuItem(
            title: StatusMenuItem.presets.title,
            action: nil,
            keyEquivalent: ""
        )
        presetsItem.image = Self.icon("bookmark", size: 16)
            ?? NSImage(systemSymbolName: "bookmark", accessibilityDescription: nil)
        presetsItem.submenu = presetsMenu
        add(presetsItem, as: .presets, to: menu)

        let scrollingItem = NSMenuItem(
            title: StatusMenuItem.scrolling.title,
            action: nil,
            keyEquivalent: ""
        )
        scrollingItem.image = Self.icon("unfold-vertical", size: 16)
        let scrollingMenu = NSMenu()
        let verticalItem = makeItem(
            L10n.tr("Vertical", "纵向"),
            action: #selector(captureScrolling)
        )
        applyKeyEquivalent(verticalItem, mode: "scrolling")
        scrollingMenu.addItem(verticalItem)
        scrollingMenu.addItem(makeItem(
            L10n.tr("Horizontal", "横向"),
            action: #selector(captureScrollingHorizontal)
        ))
        scrollingMenu.addItem(makeItem(
            L10n.tr("Auto-scroll", "自动滚动"),
            action: #selector(captureScrollingAuto)
        ))
        scrollingItem.submenu = scrollingMenu
        add(scrollingItem, as: .scrolling, to: menu)

        let recordItem = NSMenuItem(
            title: StatusMenuItem.record.title,
            action: nil,
            keyEquivalent: ""
        )
        recordItem.image = NSImage(
            systemSymbolName: "record.circle",
            accessibilityDescription: nil
        )
        let recordMenu = NSMenu()
        recordMenu.addItem(makeItem(
            L10n.tr("Record Region…", "录制区域…"),
            action: #selector(recordRegion)
        ))
        recordMenu.addItem(makeItem(
            L10n.tr("Record Screen", "录制屏幕"),
            action: #selector(recordScreen)
        ))
        recordItem.submenu = recordMenu
        add(recordItem, as: .record, to: menu)

        addSeparator(to: menu)
        let recentItem = NSMenuItem(title: StatusMenuItem.recent.title, action: nil, keyEquivalent: "")
        recentItem.image = Self.icon("clock", size: 16)
        recentItem.submenu = recentMenu
        add(recentItem, as: .recent, to: menu)
        let historyItem = makeItem(StatusMenuItem.history.title, icon: "images", action: #selector(openHistoryBrowser))
        add(historyItem, as: .history, to: menu)
        let pinsItem = NSMenuItem(
            title: StatusMenuItem.pins.title,
            action: nil,
            keyEquivalent: ""
        )
        pinsItem.image = Self.icon("pin", size: 16)
        pinsItem.submenu = pinsMenu
        add(pinsItem, as: .pins, to: menu)

        addSeparator(to: menu)
        let settingsItem = makeItem(L10n.tr("Settings…", "设置…"), icon: "settings", action: #selector(openSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        addSeparator(to: menu)

        let quitItem = makeItem(L10n.tr("Quit Snipbo", "退出 Snipbo"), icon: "log-out", action: #selector(quit))
        quitItem.keyEquivalent = "q"
        menu.addItem(quitItem)
    }

    private func add(_ item: NSMenuItem, as id: StatusMenuItem, to menu: NSMenu) {
        guard !hiddenStatusItems().contains(id) else { return }
        menu.addItem(item)
    }

    private func addSeparator(to menu: NSMenu) {
        guard menu.items.last?.isSeparatorItem == false else { return }
        menu.addItem(.separator())
    }

    private func makeItem(_ title: String, icon: String? = nil, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let icon {
            item.image = Self.icon(icon, size: 16)
        }
        return item
    }

    /// Shows the mode's registered global shortcut right-aligned in the menu,
    /// mirroring the macOS convention for menu accelerator keys.
    private func applyKeyEquivalent(_ item: NSMenuItem, mode: String) {
        guard let hotkey = hotkeyFor(mode),
              let glyph = Hotkey.keyGlyph(for: hotkey.keyCode) else { return }
        var flags: NSEvent.ModifierFlags = []
        if hotkey.modifiers.contains(.command) { flags.insert(.command) }
        if hotkey.modifiers.contains(.shift) { flags.insert(.shift) }
        if hotkey.modifiers.contains(.option) { flags.insert(.option) }
        if hotkey.modifiers.contains(.control) { flags.insert(.control) }
        item.keyEquivalent = glyph
        item.keyEquivalentModifierMask = flags
    }

    func menuWillOpen(_ menu: NSMenu) {
        lastRegionItem?.isEnabled = lastRegionAvailable()
    }

    @objc private func captureRegion() { onCapture(.region) }
    @objc private func captureWindow() { onCapture(.window) }
    @objc private func captureAppWindows() { onCapture(.appWindows) }
    @objc private func captureScreen() { onCapture(.screen) }
    @objc private func captureAllScreens() { onCapture(.allScreens) }
    @objc private func captureTimedRegion() { onCapture(.timedRegion) }
    @objc private func captureTimedScreen() { onCapture(.timedScreen) }
    @objc private func captureTimedWindow() { onCapture(.timedWindow) }
    @objc private func captureLastRegion() { onCapture(.lastRegion) }
    @objc private func captureScrolling() { onCapture(.scrolling) }
    @objc private func captureScrollingHorizontal() { onCapture(.scrollingHorizontal) }
    @objc private func captureScrollingAuto() { onCapture(.scrollingAuto) }
    @objc private func recordRegion() { onCapture(.recordRegion) }
    @objc private func recordScreen() { onCapture(.recordScreen) }
    @objc private func openSettings() { onSettings() }
    @objc private func openHistoryBrowser() { onHistoryBrowser() }
    @objc private func quit() { onQuit() }
}
