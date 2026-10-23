import AppKit
import LightShotCore

/// Builds the pure Core layout from AppKit's current screen list.
@MainActor
enum ScreenLayout {
    static func current() -> DisplayLayout {
        let nsScreens = NSScreen.screens
        let screens = nsScreens.compactMap { screen -> DisplayLayout.Screen? in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return nil }
            return DisplayLayout.Screen(
                displayID: number.uint32Value,
                frame: screen.frame,
                backingScale: screen.backingScaleFactor
            )
        }
        // The primary display is the one whose AppKit origin is (0, 0).
        let primaryHeight = nsScreens
            .first(where: { $0.frame.origin == .zero })?
            .frame.maxY
            ?? screens.map(\.frame.maxY).max()
            ?? 0
        return DisplayLayout(screens: screens, primaryHeight: primaryHeight)
    }
}
