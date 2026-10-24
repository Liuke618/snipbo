import AppKit
import CoreGraphics

@MainActor
enum PermissionService {
    /// Ask macOS at most once per process. Re-requesting on every capture is
    /// what makes the system permission dialog appear repeatedly when TCC
    /// cannot match the current build to an earlier grant.
    private static var didRequestThisLaunch = false

    static var hasScreenCaptureAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Returns true when screen recording is available. The first denial asks
    /// macOS once; later attempts show a guide instead of re-prompting.
    static func ensureScreenCaptureAccess() -> Bool {
        if hasScreenCaptureAccess { return true }
        if !didRequestThisLaunch {
            didRequestThisLaunch = true
            if CGRequestScreenCaptureAccess() {
                return true
            }
        }
        presentScreenRecordingGuide()
        return false
    }

    static func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    static func presentScreenRecordingGuide() {
        // LSUIElement apps do not become active just because a menu action ran.
        // Without this, the modal alert can be created behind the front app and
        // the capture menu appears to do nothing.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Screen Recording permission is required"
        alert.informativeText = """
        Enable LightShot in System Settings → Privacy & Security → Screen Recording.

        A granted permission only takes effect after the app restarts — use Restart below once you have toggled LightShot on.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Restart LightShot")
        alert.addButton(withTitle: "Cancel")
        alert.window.level = .floating
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            openScreenRecordingSettings()
        case .alertSecondButtonReturn:
            restartApp()
        default:
            break
        }
    }

    /// Launches a fresh instance and terminates this one, so a just-granted
    /// Screen Recording permission takes effect without a manual quit/reopen.
    private static func restartApp() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [Bundle.main.bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
