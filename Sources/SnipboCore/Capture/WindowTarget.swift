import CoreGraphics
import Foundation

/// One on-screen window offered by the window picker.
public struct WindowTarget: Equatable, Sendable {
    public let windowID: CGWindowID
    public let title: String
    public let applicationName: String
    /// CoreGraphics-global top-left frame in points (`SCWindow.frame`).
    public let frame: CGRect

    public init(windowID: CGWindowID, title: String, applicationName: String, frame: CGRect) {
        self.windowID = windowID
        self.title = title
        self.applicationName = applicationName
        self.frame = frame
    }

    public var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedApplication = applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty { return trimmedApplication }
        if trimmedApplication.isEmpty { return trimmedTitle }
        return "\(trimmedApplication) — \(trimmedTitle)"
    }
}
