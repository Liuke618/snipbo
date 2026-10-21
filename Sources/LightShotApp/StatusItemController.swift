import AppKit

@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let onCaptureRegion: () -> Void
    private let onSettings: () -> Void
    private let recentMenu: NSMenu
    private let onQuit: () -> Void

    init(
        onCaptureRegion: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        recentMenu: NSMenu,
        onQuit: @escaping () -> Void
    ) {
        self.onCaptureRegion = onCaptureRegion
        self.onSettings = onSettings
        self.recentMenu = recentMenu
        self.onQuit = onQuit
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "camera.viewfinder",
            accessibilityDescription: "LightShot"
        )

        let menu = NSMenu()
        let regionItem = NSMenuItem(title: "Capture Region", action: #selector(captureRegion), keyEquivalent: "")
        regionItem.target = self
        menu.addItem(regionItem)

        let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit LightShot", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc private func captureRegion() {
        onCaptureRegion()
    }

    @objc private func openSettings() {
        onSettings()
    }

    @objc private func quit() {
        onQuit()
    }
}
