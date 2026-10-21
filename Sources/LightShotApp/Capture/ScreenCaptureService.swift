import AppKit
import Foundation
import LightShotCore
import ScreenCaptureKit

enum CaptureError: Error, LocalizedError {
    case noDisplays
    case unmappedDisplay(CGDirectDisplayID)
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
        case let .unexpectedImageSize(displayID, expectedWidth, expectedHeight, actualWidth, actualHeight):
            return "Captured image for display \(displayID) is \(actualWidth)x\(actualHeight) pixels; expected \(expectedWidth)x\(expectedHeight) pixels."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .noDisplays, .unmappedDisplay:
            return "Make sure Screen Recording permission is granted and the display is connected, then try again."
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
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
        let screens = NSScreen.screens
        var results: [CapturedImage] = []

        for display in content.displays {
            guard let screen = screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
            }) else {
                throw CaptureError.unmappedDisplay(display.displayID)
            }

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

            results.append(CapturedImage(
                image: image,
                geometry: ScreenGeometry(
                    displayID: display.displayID,
                    frame: screen.frame,
                    backingScale: screen.backingScaleFactor
                )
            ))
        }
        return results
    }
}
