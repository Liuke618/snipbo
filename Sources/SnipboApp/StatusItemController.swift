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
    private let lastRegionAvailable: () -> Bool
    private let onQuit: () -> Void
    private var lastRegionItem: NSMenuItem?

    init(
        onCapture: @escaping (CaptureCommand) -> Void,
        onSettings: @escaping () -> Void,
        onHistoryBrowser: @escaping () -> Void,
        hotkeyFor: @escaping (String) -> Hotkey?,
        recentMenu: NSMenu,
        lastRegionAvailable: @escaping () -> Bool,
        onQuit: @escaping () -> Void
    ) {
        self.onCapture = onCapture
        self.onSettings = onSettings
        self.onHistoryBrowser = onHistoryBrowser
        self.hotkeyFor = hotkeyFor
        self.recentMenu = recentMenu
        self.lastRegionAvailable = lastRegionAvailable
        self.onQuit = onQuit
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
        let regionItem = makeItem(L10n.tr("Capture Region", "区域截图"), icon: "scan", action: #selector(captureRegion))
        applyKeyEquivalent(regionItem, mode: "region")
        menu.addItem(regionItem)

        let windowItem = makeItem(L10n.tr("Capture Window", "窗口截图"), icon: "app-window", action: #selector(captureWindow))
        applyKeyEquivalent(windowItem, mode: "window")
        menu.addItem(windowItem)

        let screenItem = makeItem(L10n.tr("Capture Screen", "屏幕截图"), icon: "monitor", action: #selector(captureScreen))
        applyKeyEquivalent(screenItem, mode: "screen")
        menu.addItem(screenItem)

        let allScreensItem = makeItem(L10n.tr("Capture All Screens", "全部屏幕"), icon: "layers", action: #selector(captureAllScreens))
        applyKeyEquivalent(allScreensItem, mode: "allScreens")
        menu.addItem(allScreensItem)

        let timedItem = NSMenuItem(title: L10n.tr("Timed Capture", "延时截图"), action: nil, keyEquivalent: "")
        timedItem.image = Self.icon("timer", size: 16)
        let timedMenu = NSMenu()
        let timedRegionSub = makeItem(L10n.tr("Region", "区域"), action: #selector(captureTimedRegion))
        applyKeyEquivalent(timedRegionSub, mode: "timedRegion")
        timedMenu.addItem(timedRegionSub)
        let timedScreenSub = makeItem(L10n.tr("Screen", "屏幕"), action: #selector(captureTimedScreen))
        applyKeyEquivalent(timedScreenSub, mode: "timedScreen")
        timedMenu.addItem(timedScreenSub)
        timedItem.submenu = timedMenu
        menu.addItem(timedItem)

        let lastRegionItem = makeItem(L10n.tr("Capture Last Region", "上次区域截图"), icon: "square-dashed", action: #selector(captureLastRegion))
        applyKeyEquivalent(lastRegionItem, mode: "lastRegion")
        self.lastRegionItem = lastRegionItem
        menu.addItem(lastRegionItem)

        let scrollingItem = makeItem(L10n.tr("Scrolling Capture", "滚动截图"), icon: "unfold-vertical", action: #selector(captureScrolling))
        applyKeyEquivalent(scrollingItem, mode: "scrolling")
        menu.addItem(scrollingItem)

        menu.addItem(.separator())
        let recentItem = NSMenuItem(title: L10n.tr("Recent", "最近截图"), action: nil, keyEquivalent: "")
        recentItem.image = Self.icon("clock", size: 16)
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)
        let historyItem = makeItem(L10n.tr("History Browser…", "历史浏览…"), icon: "images", action: #selector(openHistoryBrowser))
        menu.addItem(historyItem)

        menu.addItem(.separator())
        let settingsItem = makeItem(L10n.tr("Settings…", "设置…"), icon: "settings", action: #selector(openSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let quitItem = makeItem(L10n.tr("Quit Snipbo", "退出 Snipbo"), icon: "log-out", action: #selector(quit))
        quitItem.keyEquivalent = "q"
        menu.addItem(quitItem)
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
    @objc private func captureScreen() { onCapture(.screen) }
    @objc private func captureAllScreens() { onCapture(.allScreens) }
    @objc private func captureTimedRegion() { onCapture(.timedRegion) }
    @objc private func captureTimedScreen() { onCapture(.timedScreen) }
    @objc private func captureLastRegion() { onCapture(.lastRegion) }
    @objc private func captureScrolling() { onCapture(.scrolling) }
    @objc private func openSettings() { onSettings() }
    @objc private func openHistoryBrowser() { onHistoryBrowser() }
    @objc private func quit() { onQuit() }
}
