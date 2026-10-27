import AppKit
import SnipboCore

/// Full-screen overlay used to pick a window. The view dims the screen and
/// highlights the topmost window under the pointer. Targets are supplied in
/// front-to-back order by `ScreenCaptureService`.
@MainActor
final class WindowPickerView: NSView {
    struct Target {
        let window: WindowTarget
        /// Screen-local top-left rect in points.
        let rect: CGRect
    }

    var onPick: ((WindowTarget) -> Void)?
    var onCancel: (() -> Void)?

    private let targets: [Target]
    private var hoveredIndex: Int?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(screenFrame: CGRect, targets: [Target]) {
        self.targets = targets
        super.init(frame: CGRect(origin: .zero, size: screenFrame.size))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        NSBezierPath(rect: bounds).fill()

        guard let hoveredIndex, targets.indices.contains(hoveredIndex) else { return }
        let target = targets[hoveredIndex]
        let rect = target.rect.intersection(bounds)
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return }

        NSColor.white.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        NSColor.white.setStroke()
        let border = NSBezierPath(
            roundedRect: rect.insetBy(dx: 0.75, dy: 0.75),
            xRadius: 6,
            yRadius: 6
        )
        border.lineWidth = 1.5
        border.stroke()

        drawTitle(target.window.displayTitle, above: rect)
    }

    private func drawTitle(_ text: String, above rect: CGRect) {
        let size = PillLabel.size(for: text)
        let origin = CGPoint(
            x: max(rect.minX + 4, 4),
            y: rect.minY - size.height - 7 >= 4
                ? rect.minY - size.height - 7
                : rect.minY + 4
        )
        PillLabel.draw(text, at: origin)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveredIndex != nil else { return }
        hoveredIndex = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        updateHover(at: point)
        guard let hoveredIndex, targets.indices.contains(hoveredIndex) else {
            NSSound.beep()
            return
        }
        onPick?(targets[hoveredIndex].window)
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event) {
            super.keyDown(with: event)
        }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53 else { return false }
        onCancel?()
        return true
    }

    private func updateHover(at point: CGPoint) {
        let index = targets.firstIndex { $0.rect.contains(point) }
        guard index != hoveredIndex else { return }
        hoveredIndex = index
        needsDisplay = true
    }
}
