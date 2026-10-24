import AppKit
import SwiftUI

/// Owns the single Settings window. The controller is kept alive by
/// `AppDelegate`, so closing the window and choosing Settings again reuses the
/// same window instead of creating a second one.
@MainActor
final class SettingsWindowController: NSWindowController {
    init(model: SettingsModel) {
        // Tab bar (72) + divider (1) + the form's fixed 510 pt frame.
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 560, height: 583),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.tr("Preferences", "偏好设置")
        window.isReleasedWhenClosed = false
        // An explicitly framed hosting view pinned with autoresizing — going
        // through `contentViewController` lets AppKit adopt the hosting view's
        // own sizing, which either resizes the window on every tab switch or
        // collapses it outright once automatic sizing is disabled.
        let hostingView = NSHostingView(rootView: SettingsView(model: model))
        hostingView.frame = NSRect(x: 0, y: 0, width: 560, height: 583)
        hostingView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(hostingView)
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
