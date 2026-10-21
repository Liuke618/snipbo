import AppKit

@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let onCaptureRegion: () -> Void
    private let onCaptureTest: () -> Void
    private let onQuit: () -> Void

    init(
        onCaptureRegion: @escaping () -> Void,
        onCaptureTest: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onCaptureRegion = onCaptureRegion
        self.onCaptureTest = onCaptureTest
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

        let testItem = NSMenuItem(title: "Capture All Displays (Test)", action: #selector(captureTest), keyEquivalent: "")
        testItem.target = self
        menu.addItem(testItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit LightShot", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc private func captureRegion() {
        onCaptureRegion()
    }

    @objc private func captureTest() {
        onCaptureTest()
    }

    @objc private func quit() {
        onQuit()
    }
}
