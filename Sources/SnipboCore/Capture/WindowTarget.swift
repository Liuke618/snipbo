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

    /// The window a region selection should lock onto for a pointer at
    /// `point`: the smallest window that contains it. A small window floating
    /// over a large one wins, matching what the pointer visually rests on;
    /// nil when the point hits no window.
    public static func lockTarget(at point: CGPoint, in targets: [WindowTarget]) -> WindowTarget? {
        targets
            .filter { $0.frame.contains(point) }
            .min {
                $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
            }
    }
}
