import CoreGraphics

/// Converts between three coordinate spaces used by capture:
/// - CoreGraphics display coordinates: origin at the top-left of the primary
///   display, x right, y down. `SCWindow.frame` uses this space.
/// - AppKit global coordinates: origin at the bottom-left of the primary
///   display, x right, y up. `NSScreen.frame` and `NSEvent.mouseLocation` use
///   this space.
/// - Screen-local coordinates: origin at the top-left of one screen, x right,
///   y down. Overlay views are flipped and use this space.
public struct DisplayLayout: Equatable, Sendable {
    public struct Screen: Equatable, Sendable {
        public let displayID: CGDirectDisplayID
        /// AppKit global frame in points.
        public let frame: CGRect
        public let backingScale: CGFloat

        public init(displayID: CGDirectDisplayID, frame: CGRect, backingScale: CGFloat) {
            self.displayID = displayID
            self.frame = frame
            self.backingScale = backingScale
        }

        public var geometry: ScreenGeometry {
            ScreenGeometry(displayID: displayID, frame: frame, backingScale: backingScale)
        }
    }

    public let screens: [Screen]
    /// AppKit y of the primary display's top edge.
    public let primaryHeight: CGFloat

    public init(screens: [Screen], primaryHeight: CGFloat) {
        self.screens = screens
        self.primaryHeight = primaryHeight
    }

    /// The screen containing `point`, or `nil` if the point lies outside every
    /// screen.
    ///
    /// Point containment is inclusive of the maximum edges: a cursor resting on
    /// the bottom or right edge of a display still belongs to it (AppKit's
    /// bottom edge flips to local `y == height`). A point exactly on a boundary
    /// shared by two screens belongs to the first screen in `screens`. Area
    /// queries below stay strictly positive so zero-area overlaps are excluded.
    public func screen(containingAppKitPoint point: CGPoint) -> Screen? {
        screen(containingCGPoint: CGPoint(x: point.x, y: primaryHeight - point.y))
    }

    public func screen(containingCGPoint point: CGPoint) -> Screen? {
        screens.first { screen in
            let local = localPoint(fromCGPoint: point, on: screen)
            return local.x >= 0
                && local.y >= 0
                && local.x <= screen.frame.width
                && local.y <= screen.frame.height
        }
    }

    /// Converts a CG-global rect to a screen-local top-left rect. The result may
    /// extend outside the screen; callers clip it when drawing.
    public func localRect(fromCGRect rect: CGRect, on screen: Screen) -> CGRect {
        let offset = localOrigin(of: screen)
        return CGRect(
            x: rect.minX - offset.x,
            y: rect.minY - offset.y,
            width: rect.width,
            height: rect.height
        )
    }

    /// Converts a screen-local top-left rect back to CG-global coordinates.
    public func cgRect(fromLocalRect rect: CGRect, on screen: Screen) -> CGRect {
        let offset = localOrigin(of: screen)
        return CGRect(
            x: rect.minX + offset.x,
            y: rect.minY + offset.y,
            width: rect.width,
            height: rect.height
        )
    }

    public func screens(intersectingCGRect rect: CGRect) -> [Screen] {
        screens.filter { screen in
            let local = localRect(fromCGRect: rect, on: screen)
            let bounds = CGRect(origin: .zero, size: screen.frame.size)
            let clipped = local.intersection(bounds)
            return !clipped.isNull && clipped.width > 0 && clipped.height > 0
        }
    }

    /// The screen with the largest intersection with `rect`, used to choose a
    /// backing scale for a window that may span displays.
    public func bestScreen(forCGRect rect: CGRect) -> Screen? {
        var best: (screen: Screen, area: CGFloat)?
        for screen in screens {
            let area = intersectionArea(of: rect, on: screen)
            guard area > 0 else { continue }
            if best == nil || area > best!.area {
                best = (screen, area)
            }
        }
        return best?.screen
    }

    private func localPoint(fromCGPoint point: CGPoint, on screen: Screen) -> CGPoint {
        let offset = localOrigin(of: screen)
        return CGPoint(x: point.x - offset.x, y: point.y - offset.y)
    }

    /// CG-global position of the screen's top-left corner.
    private func localOrigin(of screen: Screen) -> CGPoint {
        CGPoint(
            x: screen.frame.minX,
            y: primaryHeight - screen.frame.maxY
        )
    }

    private func intersectionArea(of rect: CGRect, on screen: Screen) -> CGFloat {
        let local = localRect(fromCGRect: rect, on: screen)
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        let clipped = local.intersection(bounds)
        guard !clipped.isNull else { return 0 }
        return clipped.width * clipped.height
    }
}
