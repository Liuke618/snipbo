import AppKit
import Foundation
import LightShotCore
import ScreenCaptureKit

@MainActor
final class ScreenCaptureService {
    func captureAllDisplays(includeCursor: Bool) async throws -> [CapturedImage] {
        let content = try await SCShareableContent.current
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
        var results: [CapturedImage] = []

        for display in content.displays {
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
            }) else { continue }

            let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            let configuration = SCStreamConfiguration()
            configuration.width = display.width
            configuration.height = display.height
            configuration.showsCursor = includeCursor
            configuration.captureResolution = .best

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
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
