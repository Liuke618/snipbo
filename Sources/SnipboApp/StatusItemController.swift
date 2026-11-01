import AppKit
import SnipboCore

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let onCapture: (CaptureCommand) -> Void
    private let onSettings: () -> Void
    private let onHistoryBrowser: () -> Void
    private let onCheckUpdates: () -> Void
    private let hotkeyFor: (String) -> Hotkey?
    private let recentMenu: NSMenu
    private let pinsMenu: NSMenu
    private let presetsMenu: NSMenu
    private let lastRegionAvailable: () -> Bool
    private let onQuit: () -> Void
    private let hiddenStatusItems: () -> Set<StatusMenuItem>
    /// 发现新版本时返回完整的「安装更新 x.y.z」标题,菜单用该项替换
    /// 「检查更新…」;返回 nil 表示没有可安装的更新。由 AppDelegate
    /// 提供,读取 UpdateCoordinator 的当前状态。
    private let updateItemTitle: () -> String?
    private var lastRegionItem: NSMenuItem?

    init(
        onCapture: @escaping (CaptureCommand) -> Void,
        onSettings: @escaping () -> Void,
        onHistoryBrowser: @escaping () -> Void,
        onCheckUpdates: @escaping () -> Void,
        hotkeyFor: @escaping (String) -> Hotkey?,
        recentMenu: NSMenu,
        pinsMenu: NSMenu,
        presetsMenu: NSMenu,
        lastRegionAvailable: @escaping () -> Bool,
        onQuit: @escaping () -> Void,
        hiddenStatusItems: @escaping () -> Set<StatusMenuItem>,
        updateItemTitle: @escaping () -> String?
    ) {
        self.onCapture = onCapture
        self.onSettings = onSettings
        self.onHistoryBrowser = onHistoryBrowser
        self.onCheckUpdates = onCheckUpdates
        self.hotkeyFor = hotkeyFor
        self.recentMenu = recentMenu
        self.pinsMenu = pinsMenu
        self.presetsMenu = presetsMenu
        self.lastRegionAvailable = lastRegionAvailable
        self.onQuit = onQuit
        self.hiddenStatusItems = hiddenStatusItems
        self.updateItemTitle = updateItemTitle
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let icon = Self.icon("pinwheel", size: 18) {
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

    /// Exposed for probes: the built menu, so the hidden-item filter can be
    /// asserted without opening the status item.
    var statusMenu: NSMenu? { statusItem.menu }

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
    /// Parsing an SVG is expensive, so each name+size is loaded once per
    /// process and the shared instance is reused across menu rebuilds.
    private static let iconCache = NSCache<NSString, NSImage>()

    private static func icon(_ name: String, size: CGFloat) -> NSImage? {
        let key = "\(name)#\(Int(size))" as NSString
        if let cached = iconCache.object(forKey: key) { return cached }
        guard let url = Bundle.main.url(
            forResource: name,
            withExtension: "svg",
            subdirectory: "Icons"
        ), let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: size, height: size)
        iconCache.setObject(image, forKey: key)
        return image
    }

    private func populateMenu(_ menu: NSMenu) {
        addIfVisible(.region, to: menu) {
            let item = makeItem(StatusMenuItem.region.title, icon: "scan", action: #selector(captureRegion))
            applyKeyEquivalent(item, mode: "region")
            return item
        }

        addIfVisible(.window, to: menu) {
            let item = makeItem(StatusMenuItem.window.title, icon: "app-window", action: #selector(captureWindow))
            applyKeyEquivalent(item, mode: "window")
            return item
        }
        addIfVisible(.appWindows, to: menu) {
            makeItem(
                StatusMenuItem.appWindows.title,
                icon: "layers",
                action: #selector(captureAppWindows)
            )
        }

        addIfVisible(.screen, to: menu) {
            let item = makeItem(StatusMenuItem.screen.title, icon: "monitor", action: #selector(captureScreen))
            applyKeyEquivalent(item, mode: "screen")
            return item
        }

        addIfVisible(.allScreens, to: menu) {
            let item = makeItem(StatusMenuItem.allScreens.title, icon: "layers", action: #selector(captureAllScreens))
            applyKeyEquivalent(item, mode: "allScreens")
            return item
        }

        addIfVisible(.timed, to: menu) {
            let item = NSMenuItem(title: StatusMenuItem.timed.title, action: nil, keyEquivalent: "")
            item.image = Self.icon("timer", size: 16)
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
            item.submenu = timedMenu
            return item
        }

        addIfVisible(.lastRegion, to: menu) {
            let item = makeItem(StatusMenuItem.lastRegion.title, icon: "square-dashed", action: #selector(captureLastRegion))
            applyKeyEquivalent(item, mode: "lastRegion")
            self.lastRegionItem = item
            return item
        }
        addIfVisible(.presets, to: menu) {
            let item = NSMenuItem(
                title: StatusMenuItem.presets.title,
                action: nil,
                keyEquivalent: ""
            )
            item.image = Self.icon("bookmark", size: 16)
                ?? NSImage(systemSymbolName: "bookmark", accessibilityDescription: nil)
            item.submenu = presetsMenu
            return item
        }

        addIfVisible(.scrolling, to: menu) {
            let item = NSMenuItem(
                title: StatusMenuItem.scrolling.title,
                action: nil,
                keyEquivalent: ""
            )
            item.image = Self.icon("unfold-vertical", size: 16)
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
            item.submenu = scrollingMenu
            return item
        }

        addIfVisible(.record, to: menu) {
            let item = NSMenuItem(
                title: StatusMenuItem.record.title,
                action: nil,
                keyEquivalent: ""
            )
            item.image = NSImage(
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
            item.submenu = recordMenu
            return item
        }

        addSeparator(to: menu)
        addIfVisible(.recent, to: menu) {
            let item = NSMenuItem(title: StatusMenuItem.recent.title, action: nil, keyEquivalent: "")
            item.image = Self.icon("clock", size: 16)
            item.submenu = recentMenu
            return item
        }
        addIfVisible(.history, to: menu) {
            makeItem(StatusMenuItem.history.title, icon: "images", action: #selector(openHistoryBrowser))
        }
        addIfVisible(.pins, to: menu) {
            let item = NSMenuItem(
                title: StatusMenuItem.pins.title,
                action: nil,
                keyEquivalent: ""
            )
            item.image = Self.icon("pin", size: 16)
            item.submenu = pinsMenu
            return item
        }

        addSeparator(to: menu)
        let settingsItem = makeItem(L10n.tr("Settings…", "设置…"), icon: "settings", action: #selector(openSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        // 发现新版本时该项变为「安装更新 x.y.z」;点击仍然只是打开设置的
        // Updates 页(checkForUpdates 路径),绝不从菜单直接开始下载。
        let updatesTitle = updateItemTitle() ?? L10n.tr("Check for Updates…", "检查更新…")
        menu.addItem(makeItem(
            updatesTitle,
            icon: "chevrons-down",
            action: #selector(checkForUpdates)
        ))
        addSeparator(to: menu)

        let quitItem = makeItem(L10n.tr("Quit Snipbo", "退出 Snipbo"), icon: "log-out", action: #selector(quit))
        quitItem.keyEquivalent = "q"
        menu.addItem(quitItem)
    }

    /// Builds and adds the item only when it is not hidden, so a hidden item
    /// never loads its icon from disk.
    private func addIfVisible(
        _ id: StatusMenuItem,
        to menu: NSMenu,
        make: () -> NSMenuItem
    ) {
        guard !hiddenStatusItems().contains(id) else { return }
        menu.addItem(make())
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
    @objc private func checkForUpdates() { onCheckUpdates() }
    @objc private func openHistoryBrowser() { onHistoryBrowser() }
    @objc private func quit() { onQuit() }
}
