import AppKit
import SwiftUI

/// Owns the single Settings window. The controller is kept alive by
/// `AppDelegate`, so closing the window and choosing Settings again reuses the
/// same window instead of creating a second one.
@MainActor
final class SettingsWindowController: NSWindowController {
    /// Shared with the form so tab state survives view re-initialization;
    /// internal so probes can drive tab switches.
    let tabSelection = SettingsTabSelection()

    init(model: SettingsModel) {
        // Tab bar (72) + divider (1) + the form's fixed 536 pt frame.
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 560, height: 609),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.tr("Preferences", "偏好设置")
        window.isReleasedWhenClosed = false
        window.backgroundColor = DesignTokens.Color.canvasBase
        // An explicitly framed hosting view pinned with autoresizing — going
        // through `contentViewController` lets AppKit adopt the hosting view's
        // own sizing, which either resizes the window on every tab switch or
        // collapses it outright once automatic sizing is disabled.
        let hostingView = NSHostingView(
            rootView: SettingsView(model: model, tabSelection: tabSelection)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 560, height: 609)
        hostingView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(hostingView)
        window.center()
        super.init(window: window)
    }

    /// Reopening Settings resets to the General tab instead of reopening on
    /// whatever tab was last visible days ago.
    func show() {
        tabSelection.tab = .general
        tabSelection.hovered = nil
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
