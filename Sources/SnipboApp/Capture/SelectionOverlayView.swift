import AppKit
import SnipboCore

final class SelectionOverlayView: NSView {
    let captured: CapturedImage
    let selectionConstraints: SelectionConstraints
    var selection = SelectionModel()
    /// `window` is the hover-locked window when the selection came from a
    /// click on one, so the capture can be named after its owner.
    var onConfirm: ((CGRect, WindowTarget?) -> Void)?
    var onCancel: (() -> Void)?
    var onHover: (() -> Void)?

    private var anchor: CGPoint?
    private var moveAnchor: CGPoint?
    private var activeHandle: SelectionHandle?
    private var mousePoint: CGPoint = .zero
    /// NSImage wrapper over `captured.image`, built lazily on the first draw.
    /// `captured` never changes in this view's lifecycle (it is a let and the
    /// overlay window is never resized), so the wrapper is valid forever;
    /// draw() runs on every mouse move and must not re-wrap the bitmap.
    private var imageWrapper: NSImage?
    /// Layer-0 windows on this display in screen-local top-left coordinates,
    /// with their ids and owners. Drives both the WeChat-style hover lock and
    /// (when enabled in Settings) the drag edge snapping.
    private let windows: [WindowTarget]
    /// The window under the pointer while no selection is in progress.
    private(set) var hoveredWindow: WindowTarget?
    /// The window a press locked onto; a release without a drag confirms it.
    private var pendingWindow: WindowTarget?
    private var pendingDragStart: CGPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    init(
        captured: CapturedImage,
        constraints: SelectionConstraints = SelectionConstraints(),
        /// Harness seam: replaces the live CGWindowList so the hover lock can
        /// be driven deterministically without Screen Recording access.
        windowOverrides: [WindowTarget]? = nil
    ) {
        self.captured = captured
        self.selectionConstraints = constraints
        self.windows = windowOverrides ?? Self.windowTargets(from: Self.rawWindowList(), for: captured)
        super.init(frame: CGRect(origin: .zero, size: captured.geometry.frame.size))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        baseImage().draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)

        if selection.isUsable {
            // Dim only the area outside the selection. The old path drew the
            // full-screen image a second time through a clip, which doubled the
            // pixel cost on every mouse move.
            let dim = NSBezierPath(rect: bounds)
            dim.append(NSBezierPath(rect: selection.rect))
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(DesignTokens.overlayDim).setFill()
            dim.fill()

            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection.rect)
            border.lineWidth = 1
            border.stroke()
            drawHandles()
            drawSizeLabel()
        } else {
            // WeChat-style hover lock: while no selection is in progress the
            // window under the pointer stays bright and everything around it
            // dims, so a plain click reads as "capture this window".
            if let hover = hoveredWindow {
                let dim = NSBezierPath(rect: bounds)
                dim.append(NSBezierPath(rect: hover.frame))
                dim.windingRule = .evenOdd
                NSColor.black.withAlphaComponent(DesignTokens.overlayDim).setFill()
                dim.fill()
            } else {
                NSColor.black.withAlphaComponent(DesignTokens.overlayDim).setFill()
                NSBezierPath(rect: bounds).fill()
            }
            drawCrosshair()
            if let hover = hoveredWindow {
                drawHoverHighlight(hover)
            }
        }
        drawMagnifierIfNeeded()
    }

    /// Accent border around the locked window plus its title, so the lock
    /// target is legible over both light and dark content.
    private func drawHoverHighlight(_ target: WindowTarget) {
        let frame = target.frame
        NSColor.white.setStroke()
        let ring = NSBezierPath(rect: frame.insetBy(dx: -3.5, dy: -3.5))
        ring.lineWidth = 1
        ring.stroke()
        DesignTokens.overlayAccent.setStroke()
        let border = NSBezierPath(rect: frame.insetBy(dx: -1.5, dy: -1.5))
        border.lineWidth = 3
        border.stroke()

        let title = target.displayTitle
        guard !title.isEmpty else { return }
        let size = PillLabel.size(for: title)
        let x = min(max(frame.minX, 4), bounds.width - size.width - 4)
        let y = frame.minY - size.height - 6 >= 4
            ? frame.minY - size.height - 6
            : frame.minY + 6
        PillLabel.draw(title, at: CGPoint(x: x, y: y))
    }

    private func drawHandles() {
        let size: CGFloat = 6
        let points = [
            CGPoint(x: selection.rect.minX, y: selection.rect.minY),
            CGPoint(x: selection.rect.midX, y: selection.rect.minY),
            CGPoint(x: selection.rect.maxX, y: selection.rect.minY),
            CGPoint(x: selection.rect.maxX, y: selection.rect.midY),
            CGPoint(x: selection.rect.maxX, y: selection.rect.maxY),
            CGPoint(x: selection.rect.midX, y: selection.rect.maxY),
            CGPoint(x: selection.rect.minX, y: selection.rect.maxY),
            CGPoint(x: selection.rect.minX, y: selection.rect.midY),
        ]
        for point in points {
            let rect = CGRect(
                x: point.x - size / 2,
                y: point.y - size / 2,
                width: size,
                height: size
            )
            let handle = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
            NSColor.white.setFill()
            handle.fill()
            NSColor.black.withAlphaComponent(DesignTokens.overlayHandleStroke).setStroke()
            handle.lineWidth = 0.5
            handle.stroke()
        }
    }

    private func drawSizeLabel() {
        let text = "\(Int(selection.rect.width)) × \(Int(selection.rect.height))"
        let size = PillLabel.size(for: text)
        let origin = CGPoint(
            x: min(max(selection.rect.minX, 4), bounds.width - size.width - 4),
            y: max(selection.rect.minY - size.height - 6, 4)
        )
        PillLabel.draw(text, at: origin)
    }

    private func drawCrosshair() {
        guard mousePoint != .zero else { return }
        NSColor.white.withAlphaComponent(0.8).setStroke()
        let path = NSBezierPath()
        path.move(to: CGPoint(x: mousePoint.x, y: 0))
        path.line(to: CGPoint(x: mousePoint.x, y: bounds.height))
        path.move(to: CGPoint(x: 0, y: mousePoint.y))
        path.line(to: CGPoint(x: bounds.width, y: mousePoint.y))
        path.lineWidth = 0.5
        path.stroke()
    }

    private func drawMagnifierIfNeeded() {
        guard !selection.isUsable, mousePoint != .zero else { return }
        let zoom: CGFloat = 4
        let diameter: CGFloat = 120
        let sourceSize = diameter / zoom
        let sourceRect = CGRect(
            x: mousePoint.x - sourceSize / 2,
            y: mousePoint.y - sourceSize / 2,
            width: sourceSize,
            height: sourceSize
        )
        let pixelRect = captured.geometry.pixelRect(fromLocalPoints: sourceRect)
        guard let cropped = captured.image.cropping(to: pixelRect) else { return }

        let origin = CGPoint(
            x: min(mousePoint.x + 24, bounds.width - diameter - 8),
            y: min(mousePoint.y + 24, bounds.height - diameter - 8)
        )
        let frame = CGRect(origin: origin, size: CGSize(width: diameter, height: diameter))
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: frame).addClip()
        if let context = NSGraphicsContext.current?.cgContext {
            // View coordinates are flipped; CGImage draws from the bottom-left
            // origin, so flip once around the target rect's center or the lens
            // content ends up upside down. Drawing the cropped CGImage directly
            // avoids wrapping it in a fresh NSImage on every mouse move.
            context.translateBy(x: frame.midX, y: frame.midY)
            context.scaleBy(x: 1, y: -1)
            context.draw(cropped, in: CGRect(
                x: -frame.width / 2,
                y: -frame.height / 2,
                width: frame.width,
                height: frame.height
            ))
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.setStroke()
        let outline = NSBezierPath(ovalIn: frame)
        outline.lineWidth = 1
        outline.stroke()
        // A hairline black ring keeps the lens visible over light content.
        NSColor.black.withAlphaComponent(DesignTokens.overlayLensRing).setStroke()
        let outer = NSBezierPath(ovalIn: frame.insetBy(dx: -1, dy: -1))
        outer.lineWidth = 1
        outer.stroke()
    }

    /// The cached full-screenshot wrapper (see `imageWrapper`).
    private func baseImage() -> NSImage {
        if let imageWrapper { return imageWrapper }
        let image = NSImage(cgImage: captured.image, size: bounds.size)
        imageWrapper = image
        return image
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        mousePoint = point
        onHover?()
        if event.clickCount == 2, selection.isUsable {
            onConfirm?(selection.rect, nil)
            return
        }

        anchor = nil
        moveAnchor = nil
        activeHandle = nil
        pendingWindow = nil
        // With no usable selection every click starts a new one; a zero rect is
        // within handle tolerance of the origin and must not act as a resize.
        if selection.isUsable,
           let handle = selection.handle(at: point, tolerance: 8),
           handle != .inside {
            activeHandle = handle
            hoveredWindow = nil
        } else if selection.isUsable, selection.rect.contains(point) {
            activeHandle = .inside
            moveAnchor = point
            hoveredWindow = nil
        } else {
            anchor = point
            selection = SelectionModel()
            // WeChat-style lock: pressing on a highlighted window captures it
            // on release, unless the pointer drags away into a free region.
            hoveredWindow = WindowTarget.lockTarget(at: point, in: windows)
            pendingWindow = hoveredWindow
            pendingDragStart = point
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mousePoint = point
        if let anchor {
            let clamped = CGPoint(
                x: min(max(point.x, bounds.minX), bounds.maxX),
                y: min(max(point.y, bounds.minY), bounds.maxY)
            )
            selection = SelectionModel(rect: newSelectionRect(anchor: anchor, point: clamped))
        } else if activeHandle == .inside, let moveAnchor {
            // SelectionModel.drag(.inside) centers the rect on the supplied point,
            // so pass the center plus the pointer delta to keep the grab offset.
            let delta = CGPoint(x: point.x - moveAnchor.x, y: point.y - moveAnchor.y)
            selection.drag(
                handle: .inside,
                to: CGPoint(x: selection.rect.midX + delta.x, y: selection.rect.midY + delta.y),
                constrainedTo: bounds
            )
            self.moveAnchor = point
        } else if let activeHandle {
            selection.drag(handle: activeHandle, to: point, constrainedTo: bounds)
            var rect = selection.rect
            if let ratio = selectionConstraints.aspectRatio {
                rect = aspectAdjusted(rect, handle: activeHandle, ratio: ratio)
            }
            rect = snapped(rect, handle: activeHandle)
            selection = SelectionModel(rect: clamped(rect))
        }
        needsDisplay = true
    }

    /// Rect for a new drag. Fixed size wins over the aspect ratio; snapping is
    /// only applied to unconstrained drags so it cannot fight either rule.
    private func newSelectionRect(anchor: CGPoint, point: CGPoint) -> CGRect {
        if let fixed = selectionConstraints.fixedSize {
            let size = CGSize(
                width: max(1, fixed.width),
                height: max(1, fixed.height)
            )
            var origin = anchor
            if point.x < anchor.x { origin.x = anchor.x - size.width }
            if point.y < anchor.y { origin.y = anchor.y - size.height }
            return clamped(CGRect(origin: origin, size: size))
        }

        var rect = CGRect(
            x: min(anchor.x, point.x),
            y: min(anchor.y, point.y),
            width: abs(point.x - anchor.x),
            height: abs(point.y - anchor.y)
        )
        if let ratio = selectionConstraints.aspectRatio {
            let signX: CGFloat = point.x < anchor.x ? -1 : 1
            let signY: CGFloat = point.y < anchor.y ? -1 : 1
            var width = max(1, rect.width)
            var height = max(1, rect.height)
            if width / height > ratio {
                height = width / ratio
            } else {
                width = height * ratio
            }
            let maxWidth = signX > 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX
            let maxHeight = signY > 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY
            width = min(width, max(1, maxWidth))
            height = min(height, max(1, maxHeight))
            if width / height > ratio {
                height = width / ratio
            } else {
                width = height * ratio
            }
            let x = signX > 0 ? anchor.x : anchor.x - width
            let y = signY > 0 ? anchor.y : anchor.y - height
            rect = CGRect(x: x, y: y, width: width, height: height)
        } else {
            rect = snapped(
                rect,
                left: point.x < anchor.x,
                right: point.x >= anchor.x,
                top: point.y < anchor.y,
                bottom: point.y >= anchor.y
            )
        }
        return clamped(rect)
    }

    /// Keeps the aspect ratio while dragging a handle. Corner handles pin the
    /// opposite corner; edge handles grow symmetrically around the opposite
    /// edge's midpoint.
    private func aspectAdjusted(
        _ rect: CGRect,
        handle: SelectionHandle,
        ratio: CGFloat
    ) -> CGRect {
        guard rect.width > 0, rect.height > 0 else { return rect }
        switch handle {
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            var width = rect.width
            var height = rect.height
            if width / height > ratio {
                height = width / ratio
            } else {
                width = height * ratio
            }
            let origin: CGPoint
            switch handle {
            case .topLeft:
                origin = CGPoint(x: rect.maxX - width, y: rect.maxY - height)
            case .topRight:
                origin = CGPoint(x: rect.minX, y: rect.maxY - height)
            case .bottomLeft:
                origin = CGPoint(x: rect.maxX - width, y: rect.minY)
            default:
                origin = CGPoint(x: rect.minX, y: rect.minY)
            }
            return CGRect(origin: origin, size: CGSize(width: width, height: height))
        case .left, .right:
            let height = rect.width / ratio
            return CGRect(
                x: rect.minX,
                y: rect.midY - height / 2,
                width: rect.width,
                height: height
            )
        case .top, .bottom:
            let width = rect.height * ratio
            return CGRect(
                x: rect.midX - width / 2,
                y: rect.minY,
                width: width,
                height: rect.height
            )
        case .inside:
            return rect
        }
    }

    private func snapped(
        _ rect: CGRect,
        handle: SelectionHandle
    ) -> CGRect {
        switch handle {
        case .topLeft:
            return snapped(rect, left: true, right: false, top: true, bottom: false)
        case .topRight:
            return snapped(rect, left: false, right: true, top: true, bottom: false)
        case .bottomRight:
            return snapped(rect, left: false, right: true, top: false, bottom: true)
        case .bottomLeft:
            return snapped(rect, left: true, right: false, top: false, bottom: true)
        case .left:
            return snapped(rect, left: true, right: false, top: false, bottom: false)
        case .right:
            return snapped(rect, left: false, right: true, top: false, bottom: false)
        case .top:
            return snapped(rect, left: false, right: false, top: true, bottom: false)
        case .bottom:
            return snapped(rect, left: false, right: false, top: false, bottom: true)
        case .inside:
            return rect
        }
    }

    private func snapped(
        _ rect: CGRect,
        left: Bool,
        right: Bool,
        top: Bool,
        bottom: Bool
    ) -> CGRect {
        guard selectionConstraints.snapToWindows,
              selectionConstraints.fixedSize == nil,
              selectionConstraints.aspectRatio == nil,
              !windows.isEmpty else {
            return rect
        }
        var result = rect
        let xEdges = windows.flatMap { [$0.frame.minX, $0.frame.maxX] }
            + [bounds.minX, bounds.maxX]
        let yEdges = windows.flatMap { [$0.frame.minY, $0.frame.maxY] }
            + [bounds.minY, bounds.maxY]
        if left, let x = nearest(rect.minX, in: xEdges) {
            result.origin.x = x
            result.size.width = rect.maxX - x
        }
        if right, let x = nearest(rect.maxX, in: xEdges) {
            result.size.width = x - result.minX
        }
        if top, let y = nearest(rect.minY, in: yEdges) {
            result.origin.y = y
            result.size.height = rect.maxY - y
        }
        if bottom, let y = nearest(rect.maxY, in: yEdges) {
            result.size.height = y - result.minY
        }
        return result
    }

    private func nearest(_ value: CGFloat, in edges: [CGFloat]) -> CGFloat? {
        let tolerance: CGFloat = 6
        return edges
            .filter { abs($0 - value) <= tolerance }
            .min { abs($0 - value) < abs($1 - value) }
    }

    private func clamped(_ rect: CGRect) -> CGRect {
        var result = rect
        result.size.width = min(max(result.width, 1), bounds.width)
        result.size.height = min(max(result.height, 1), bounds.height)
        result.origin.x = min(max(result.origin.x, bounds.minX), bounds.maxX - result.width)
        result.origin.y = min(max(result.origin.y, bounds.minY), bounds.maxY - result.height)
        return result
    }

    /// Layer-0 on-screen windows of other apps on this display, in screen-local
    /// top-left coordinates. `kCGWindowName` needs Screen Recording access,
    /// which the app already holds; without it the title falls back to the
    /// owner name through `displayTitle`.
    ///
    /// `rawList` is a shared CGWindowList snapshot (see `rawWindowList()`) so
    /// every display overlay filters the same copy instead of each copying the
    /// global window list.
    static func windowTargets(
        from rawList: [[String: Any]],
        for captured: CapturedImage
    ) -> [WindowTarget] {
        let layout = ScreenLayout.current()
        guard let screen = layout.screens.first(where: {
            $0.displayID == captured.geometry.displayID
        }) else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let screenBounds = CGRect(origin: .zero, size: screen.frame.size)
        var targets: [WindowTarget] = []
        for entry in rawList {
            guard let owner = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  owner != ownPID,
                  let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  width > 2, height > 2 else {
                continue
            }
            let global = CGRect(x: x, y: y, width: width, height: height)
            let local = layout.localRect(fromCGRect: global, on: screen)
            let clipped = local.intersection(screenBounds)
            guard !clipped.isNull, clipped.width > 2, clipped.height > 2 else {
                continue
            }
            let windowID = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
            let title = entry[kCGWindowName as String] as? String ?? ""
            let applicationName = entry[kCGWindowOwnerName as String] as? String ?? ""
            targets.append(WindowTarget(
                windowID: windowID,
                title: title,
                applicationName: applicationName,
                frame: clipped
            ))
        }
        return targets
    }

    /// One global CGWindowList snapshot for all display overlays of a capture;
    /// `CGWindowListCopyWindowInfo` copies every on-screen window each call.
    static func rawWindowList() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]) ?? []
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            anchor = nil
            moveAnchor = nil
            activeHandle = nil
            pendingWindow = nil
            pendingDragStart = nil
            needsDisplay = true
        }
        // A press-and-release on a locked window captures it; the drag anchor
        // only turns into a free selection once the pointer travels.
        if let pending = pendingWindow, let start = pendingDragStart {
            let point = convert(event.locationInWindow, from: nil)
            if hypot(point.x - start.x, point.y - start.y) < 4 {
                selection = SelectionModel()
                onConfirm?(pending.frame, pending)
                return
            }
        }
        if !selection.isUsable {
            selection = SelectionModel()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        mousePoint = convert(event.locationInWindow, from: nil)
        onHover?()
        if anchor == nil, activeHandle == nil, !selection.isUsable {
            let hover = WindowTarget.lockTarget(at: mousePoint, in: windows)
            if hover != hoveredWindow {
                hoveredWindow = hover
            }
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event) {
            super.keyDown(with: event)
        }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 36:
            guard selection.isUsable else {
                NSSound.beep()
                return true
            }
            onConfirm?(selection.rect, nil)
            return true
        case 53:
            onCancel?()
            return true
        case 123, 124, 125, 126:
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let resize = event.modifierFlags.contains(.option)
            if resize {
                // Option+arrow moves that boundary outward in the arrow's
                // direction: Left widens from the left edge, Up from the top.
                switch event.keyCode {
                case 123: selection.resize(edge: .left, by: step, constrainedTo: bounds)
                case 124: selection.resize(edge: .right, by: step, constrainedTo: bounds)
                case 125: selection.resize(edge: .bottom, by: step, constrainedTo: bounds)
                default: selection.resize(edge: .top, by: step, constrainedTo: bounds)
                }
            } else {
                switch event.keyCode {
                case 123: selection.nudge(dx: -step, dy: 0, resize: false, constrainedTo: bounds)
                case 124: selection.nudge(dx: step, dy: 0, resize: false, constrainedTo: bounds)
                case 125: selection.nudge(dx: 0, dy: step, resize: false, constrainedTo: bounds)
                default: selection.nudge(dx: 0, dy: -step, resize: false, constrainedTo: bounds)
                }
            }
            needsDisplay = true
            return true
        default:
            return false
        }
    }
}
