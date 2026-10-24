import CoreGraphics
import Foundation

/// The last confirmed region capture, persisted so it can be repeated after a
/// relaunch. It is only valid while the same display keeps the same frame and
/// backing scale.
public struct LastRegion: Codable, Equatable, Sendable {
    public let displayID: CGDirectDisplayID
    /// Screen-local top-left rect in points.
    public let rect: CGRect
    /// AppKit-global screen frame in points.
    public let screenFrame: CGRect
    public let backingScale: CGFloat

    public init(
        displayID: CGDirectDisplayID,
        rect: CGRect,
        screenFrame: CGRect,
        backingScale: CGFloat
    ) {
        self.displayID = displayID
        self.rect = rect
        self.screenFrame = screenFrame
        self.backingScale = backingScale
    }

    public func isValid(for geometry: ScreenGeometry) -> Bool {
        guard displayID == geometry.displayID,
              screenFrame == geometry.frame,
              abs(backingScale - geometry.backingScale) < 0.001 else {
            return false
        }
        guard rect.width >= 1, rect.height >= 1 else { return false }
        return CGRect(origin: .zero, size: screenFrame.size).contains(rect)
    }
}
