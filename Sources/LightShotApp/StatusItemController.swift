import AppKit

@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let onCapture: (CaptureCommand) -> Void
    private let onSettings: () -> Void
    private let recentMenu: NSMenu
    private let onQuit: () -> Void

    init(
        onCapture: @escaping (CaptureCommand) -> Void,
        onSettings: @escaping () -> Void,
        recentMenu: NSMenu,
        onQuit: @escaping () -> Void
    ) {
        self.onCapture = onCapture
        self.onSettings = onSettings
        self.recentMenu = recentMenu
        self.onQuit = onQuit
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "camera.viewfinder",
            accessibilityDescription: "LightShot"
        )

        let menu = NSMenu()
        menu.addItem(makeItem("Capture Region", action: #selector(captureRegion)))
        menu.addItem(makeItem("Capture Window", action: #selector(captureWindow)))
        menu.addItem(makeItem("Capture Screen", action: #selector(captureScreen)))
        menu.addItem(makeItem("Capture All Screens", action: #selector(captureAllScreens)))

        let timedItem = NSMenuItem(title: "Timed Capture", action: nil, keyEquivalent: "")
        let timedMenu = NSMenu()
        timedMenu.addItem(makeItem("Region", action: #selector(captureTimedRegion)))
        timedMenu.addItem(makeItem("Screen", action: #selector(captureTimedScreen)))
        timedItem.submenu = timedMenu
        menu.addItem(timedItem)

        menu.addItem(.separator())

        let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        menu.addItem(.separator())
        let settingsItem = makeItem("Settings…", action: #selector(openSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let quitItem = makeItem("Quit LightShot", action: #selector(quit))
        quitItem.keyEquivalent = "q"
        menu.addItem(quitItem)
        statusItem.menu = menu
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
    @objc private func openSettings() { onSettings() }
    @objc private func quit() { onQuit() }
}
