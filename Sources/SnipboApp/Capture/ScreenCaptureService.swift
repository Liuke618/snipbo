import AppKit
import Foundation
import SnipboCore
import ScreenCaptureKit

enum CaptureError: Error, LocalizedError {
    case noDisplays
    case unmappedDisplay(CGDirectDisplayID)
    case displayNotFound(CGDirectDisplayID)
    case screenNotFound
    case timedOut
    case windowNotFound(CGWindowID)
    case noWindows
    case compositionFailed
    case unexpectedImageSize(
        displayID: CGDirectDisplayID,
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int,
        actualHeight: Int
    )

    var errorDescription: String? {
        switch self {
        case .noDisplays:
            return "ScreenCaptureKit returned no displays to capture."
        case .unmappedDisplay(let displayID):
            return "No screen matches display ID \(displayID)."
        case .displayNotFound(let displayID):
            return "Display \(displayID) is no longer connected."
        case .screenNotFound:
            return "Could not determine the display under the pointer."
        case .timedOut:
            return "Screen capture did not respond in time."
        case .windowNotFound(let windowID):
            return "The window \(windowID) is no longer available."
        case .noWindows:
            return "No capturable windows were found."
        case .compositionFailed:
            return "The screens could not be combined into one image."
        case let .unexpectedImageSize(displayID, expectedWidth, expectedHeight, actualWidth, actualHeight):
            return "Captured image for display \(displayID) is \(actualWidth)x\(actualHeight) pixels; expected \(expectedWidth)x\(expectedHeight) pixels."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .noDisplays, .unmappedDisplay:
            return "Make sure Screen Recording permission is granted and the display is connected, then try again."
        case .displayNotFound:
            return "Reconnect the display or capture the screen under the pointer instead."
        case .screenNotFound:
            return "Move the pointer over a display and try again."
        case .timedOut:
            return "Check Screen Recording permission, then quit and reopen Snipbo. If the app was rebuilt, sign it with a stable identity so macOS keeps the permission."
        case .windowNotFound, .noWindows:
            return "The window may have closed. Try again."
        case .compositionFailed:
            return "Try capturing a single screen."
        case .unexpectedImageSize:
            return "The display may have changed resolution during capture. Try again."
        }
    }
}

@MainActor
final class ScreenCaptureService {
    func captureAllDisplays(includeCursor: Bool) async throws -> [CapturedImage] {
        let content = try await SCShareableContent.current
        guard !content.displays.isEmpty else {
            throw CaptureError.noDisplays
        }
        let excluded = ownWindows(in: content)
        var results: [CapturedImage] = []
        for display in content.displays {
            guard let screen = screen(for: display.displayID) else {
                throw CaptureError.unmappedDisplay(display.displayID)
            }
            results.append(try await capture(
                display: display,
                screen: screen,
                includeCursor: includeCursor,
                excluding: excluded
            ))
        }
        return results
    }

    func captureDisplay(displayID: CGDirectDisplayID, includeCursor: Bool) async throws -> CapturedImage {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound(displayID)
        }
        guard let screen = screen(for: displayID) else {
            throw CaptureError.unmappedDisplay(displayID)
        }
        return try await capture(
            display: display,
            screen: screen,
            includeCursor: includeCursor,
            excluding: ownWindows(in: content)
        )
    }

    /// All capturable windows in front-to-back order. Windows owned by
    /// Snipbo are excluded so its own overlays can never be picked.
    func windowInventory() async throws -> [WindowTarget] {
        let content = try await SCShareableContent.current
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let order = windowOrder()
        let targets = content.windows.compactMap { window -> WindowTarget? in
            guard window.isOnScreen,
                  window.windowLayer == 0,
                  window.frame.width >= 8,
                  window.frame.height >= 8,
                  let application = window.owningApplication,
                  application.processID != ownPID else {
                return nil
            }
            return WindowTarget(
                windowID: window.windowID,
                title: window.title ?? "",
                applicationName: application.applicationName,
                frame: window.frame
            )
        }
        guard !targets.isEmpty else {
            throw CaptureError.noWindows
        }
        return targets.sorted {
            (order[$0.windowID] ?? Int.max) < (order[$1.windowID] ?? Int.max)
        }
    }

    func captureWindow(windowID: CGWindowID, includeCursor: Bool) async throws -> CapturedImage {
        let content = try await SCShareableContent.current
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound(windowID)
        }
        let layout = ScreenLayout.current()
        guard let screen = layout.bestScreen(forCGRect: window.frame) else {
            throw CaptureError.screenNotFound
        }

        // The capture configuration is in pixels. Choose the backing scale of
        // the screen with the largest intersection so a spanning window keeps
        // native detail on the display that shows most of it.
        let scale = screen.backingScale
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((window.frame.width * scale).rounded()))
        configuration.height = max(1, Int((window.frame.height * scale).rounded()))
        configuration.showsCursor = includeCursor
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration
        )
        guard image.width > 0, image.height > 0 else {
            throw CaptureError.windowNotFound(windowID)
        }
        return CapturedImage(
            image: image,
            geometry: ScreenGeometry(
                displayID: screen.displayID,
                frame: CGRect(origin: .zero, size: window.frame.size),
                backingScale: scale
            )
        )
    }

    private func capture(
        display: SCDisplay,
        screen: NSScreen,
        includeCursor: Bool,
        excluding ownWindows: [SCWindow]
    ) async throws -> CapturedImage {
        // SCDisplay reports its size in points, while SCStreamConfiguration
        // expects pixels. Multiply by the screen's backing scale so a 2x
        // display captures at native pixel resolution and the bitmap matches
        // the backingScale recorded in ScreenGeometry.
        let scale = screen.backingScaleFactor
        let expectedWidth = Int(CGFloat(display.width) * scale)
        let expectedHeight = Int(CGFloat(display.height) * scale)

        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let configuration = SCStreamConfiguration()
        configuration.width = expectedWidth
        configuration.height = expectedHeight
        configuration.showsCursor = includeCursor
        configuration.captureResolution = .best

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )

        guard image.width == expectedWidth, image.height == expectedHeight else {
            throw CaptureError.unexpectedImageSize(
                displayID: display.displayID,
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight,
                actualWidth: image.width,
                actualHeight: image.height
            )
        }

        return CapturedImage(
            image: image,
            geometry: ScreenGeometry(
                displayID: display.displayID,
                frame: screen.frame,
                backingScale: screen.backingScaleFactor
            )
        )
    }

    private func ownWindows(in content: SCShareableContent) -> [SCWindow] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.filter { $0.owningApplication?.processID == ownPID }
    }

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    /// CGWindowList order is front-to-back; SCShareableContent does not
    /// guarantee an order, so use the window server's order for hit testing.
    private func windowOrder() -> [CGWindowID: Int] {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return [:]
        }
        var order: [CGWindowID: Int] = [:]
        for (index, entry) in info.enumerated() {
            if let number = entry[kCGWindowNumber as String] as? NSNumber {
                order[number.uint32Value] = index
            }
        }
        return order
    }
}
