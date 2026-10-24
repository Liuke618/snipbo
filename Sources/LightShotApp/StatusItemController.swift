import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let onCapture: (CaptureCommand) -> Void
    private let onSettings: () -> Void
    private let onHistoryBrowser: () -> Void
    private let recentMenu: NSMenu
    private let lastRegionAvailable: () -> Bool
    private let onQuit: () -> Void
    private var lastRegionItem: NSMenuItem?

    init(
        onCapture: @escaping (CaptureCommand) -> Void,
        onSettings: @escaping () -> Void,
        onHistoryBrowser: @escaping () -> Void,
        recentMenu: NSMenu,
        lastRegionAvailable: @escaping () -> Bool,
        onQuit: @escaping () -> Void
    ) {
        self.onCapture = onCapture
        self.onSettings = onSettings
        self.onHistoryBrowser = onHistoryBrowser
        self.recentMenu = recentMenu
        self.lastRegionAvailable = lastRegionAvailable
        self.onQuit = onQuit
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "camera.viewfinder",
            accessibilityDescription: "LightShot"
        )

        let menu = NSMenu()
        menu.delegate = self
        populateMenu(menu)
        statusItem.menu = menu
    }

    /// Rebuilds every item so a language change takes effect the next time
    /// the menu opens.
    func refreshLocalization() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        populateMenu(menu)
    }

    private func populateMenu(_ menu: NSMenu) {
        menu.addItem(makeItem(L10n.tr("Capture Region", "区域截图"), action: #selector(captureRegion)))
        menu.addItem(makeItem(L10n.tr("Capture Window", "窗口截图"), action: #selector(captureWindow)))
        menu.addItem(makeItem(L10n.tr("Capture Screen", "屏幕截图"), action: #selector(captureScreen)))
        menu.addItem(makeItem(L10n.tr("Capture All Screens", "全部屏幕"), action: #selector(captureAllScreens)))

        let timedItem = NSMenuItem(title: L10n.tr("Timed Capture", "延时截图"), action: nil, keyEquivalent: "")
        let timedMenu = NSMenu()
        timedMenu.addItem(makeItem(L10n.tr("Region", "区域"), action: #selector(captureTimedRegion)))
        timedMenu.addItem(makeItem(L10n.tr("Screen", "屏幕"), action: #selector(captureTimedScreen)))
        timedItem.submenu = timedMenu
        menu.addItem(timedItem)

        let lastRegionItem = makeItem(L10n.tr("Capture Last Region", "上次区域截图"), action: #selector(captureLastRegion))
        self.lastRegionItem = lastRegionItem
        menu.addItem(lastRegionItem)
        menu.addItem(makeItem(L10n.tr("Scrolling Capture", "滚动截图"), action: #selector(captureScrolling)))

        menu.addItem(.separator())
        let recentItem = NSMenuItem(title: L10n.tr("Recent", "最近截图"), action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)
        menu.addItem(makeItem(L10n.tr("History Browser…", "历史浏览…"), action: #selector(openHistoryBrowser)))

        menu.addItem(.separator())
        let settingsItem = makeItem(L10n.tr("Settings…", "设置…"), action: #selector(openSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let quitItem = makeItem(L10n.tr("Quit LightShot", "退出 LightShot"), action: #selector(quit))
        quitItem.keyEquivalent = "q"
        menu.addItem(quitItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        lastRegionItem?.isEnabled = lastRegionAvailable()
    }

    private func makeItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
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
