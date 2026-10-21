import AppKit

@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let onCaptureTest: () -> Void
    private let onQuit: () -> Void

    init(onCaptureTest: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.onCaptureTest = onCaptureTest
        self.onQuit = onQuit
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "camera.viewfinder",
            accessibilityDescription: "LightShot"
        )

        let menu = NSMenu()
        let testItem = NSMenuItem(title: "Capture All Displays (Test)", action: #selector(captureTest), keyEquivalent: "")
        testItem.target = self
        menu.insertItem(testItem, at: 0)
        menu.insertItem(.separator(), at: 1)
        let quitItem = NSMenuItem(title: "Quit LightShot", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc private func captureTest() {
        onCaptureTest()
    }

    @objc private func quit() {
        onQuit()
    }
}
