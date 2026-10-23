import AppKit
import SwiftUI

/// Owns the single Settings window. The controller is kept alive by
/// `AppDelegate`, so closing the window and choosing Settings again reuses the
/// same window instead of creating a second one.
@MainActor
final class SettingsWindowController: NSWindowController {
    init(model: SettingsModel) {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 560, height: 680),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "LightShot Settings"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
        // The hosting controller sizes the window to the form's ideal height,
        // including the optional JPEG quality row. The form owns the width.
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
