import AppKit
import Foundation
import SnipboCore
@preconcurrency import ScreenCaptureKit

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
            return L10n.tr(
                "ScreenCaptureKit returned no displays to capture.",
                "ScreenCaptureKit 没有返回可截取的显示器。"
            )
        case .unmappedDisplay(let displayID):
            return L10n.tr(
                "No screen matches display ID \(displayID).",
                "没有与显示器 \(displayID) 匹配的屏幕。"
            )
        case .displayNotFound(let displayID):
            return L10n.tr(
                "Display \(displayID) is no longer connected.",
                "显示器 \(displayID) 已断开连接。"
            )
        case .screenNotFound:
            return L10n.tr(
                "Could not determine the display under the pointer.",
                "无法确定指针所在的显示器。"
            )
        case .timedOut:
            return L10n.tr(
                "Screen capture did not respond in time.",
                "截图请求超时。"
            )
        case .windowNotFound(let windowID):
            return L10n.tr(
                "The window \(windowID) is no longer available.",
                "窗口 \(windowID) 已不可用。"
            )
        case .noWindows:
            return L10n.tr(
                "No capturable windows were found.",
                "没有找到可截取的窗口。"
            )
        case .compositionFailed:
            return L10n.tr(
                "The screens could not be combined into one image.",
                "无法把多个屏幕合成为一张图。"
            )
        case let .unexpectedImageSize(displayID, expectedWidth, expectedHeight, actualWidth, actualHeight):
            return L10n.tr(
                "Captured image for display \(displayID) is \(actualWidth)x\(actualHeight) pixels; expected \(expectedWidth)x\(expectedHeight) pixels.",
                "显示器 \(displayID) 的截图为 \(actualWidth)x\(actualHeight) 像素，预期为 \(expectedWidth)x\(expectedHeight) 像素。"
            )
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .noDisplays, .unmappedDisplay:
            return L10n.tr(
                "Make sure Screen Recording permission is granted and the display is connected, then try again.",
                "请确认已授予屏幕录制权限且显示器已连接，然后重试。"
            )
        case .displayNotFound:
            return L10n.tr(
                "Reconnect the display or capture the screen under the pointer instead.",
                "请重新连接显示器，或改为截取指针所在的屏幕。"
            )
        case .screenNotFound:
            return L10n.tr(
                "Move the pointer over a display and try again.",
                "请把指针移到某个显示器上再试。"
            )
        case .timedOut:
            return L10n.tr(
                "Check Screen Recording permission, then quit and reopen Snipbo. If the app was rebuilt, sign it with a stable identity so macOS keeps the permission.",
                "请检查屏幕录制权限，然后退出并重新打开 Snipbo。如果应用是重新构建的，请使用稳定签名，让 macOS 保留权限。"
            )
        case .windowNotFound, .noWindows:
            return L10n.tr(
                "The window may have closed. Try again.",
                "窗口可能已关闭，请重试。"
            )
        case .compositionFailed:
            return L10n.tr(
                "Try capturing a single screen.",
                "请尝试只截取单个屏幕。"
            )
        case .unexpectedImageSize:
            return L10n.tr(
                "The display may have changed resolution during capture. Try again.",
                "显示器可能在截图期间改变了分辨率，请重试。"
            )
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
        var tasks: [(index: Int, task: Task<CapturedImage, Error>)] = []
        for (index, display) in content.displays.enumerated() {
            guard let screen = screen(for: display.displayID) else {
                throw CaptureError.unmappedDisplay(display.displayID)
            }
            // Each capture suspends while ScreenCaptureKit encodes, so the
            // displays are requested concurrently and the wait is the slowest
            // one instead of their sum.
            let task = Task { @MainActor in
                try await capture(
                    display: display,
                    screen: screen,
                    includeCursor: includeCursor,
                    excluding: excluded
                )
            }
            tasks.append((index, task))
        }
        var results = [CapturedImage?](repeating: nil, count: tasks.count)
        do {
            for (index, task) in tasks {
                results[index] = try await task.value
            }
        } catch {
            tasks.forEach { $0.task.cancel() }
            throw error
        }
        return results.compactMap { $0 }
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
