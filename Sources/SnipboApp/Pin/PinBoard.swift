import AppKit
import ImageIO
import SnipboCore

extension Notification.Name {
    /// Posted on the main actor whenever a pin opens, closes, or is restored.
    static let snipboPinsDidChange = Notification.Name("snipboPinsDidChange")
}

/// Owns the floating pin windows. Pins are draggable, wheel-resizable,
/// always-on-top screenshots; Cmd+C copies and Esc closes. They are persisted
/// under Application Support and restored on the next launch.
@MainActor
final class PinBoard {
    static let shared = PinBoard()

    struct ManagedPin: Identifiable, Equatable {
        let id: UUID
        let title: String
    }

    private let store = PinStore()
    private var pins: [PinWindowController] = []
    private var pendingFrames: [UUID: CGRect] = [:]
    private var frameSaveTask: Task<Void, Never>?

    private init() {}

    /// Reopens every persisted pin without taking focus from the front app.
    func restore() {
        Task { [weak self] in
            guard let self else { return }
            let items = await store.load()
            guard !items.isEmpty else { return }
            for item in items {
                let url = store.directory.appendingPathComponent(item.imageFileName)
                let payload = await Task.detached(priority: .userInitiated) { () -> ImageData? in
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                        return nil
                    }
                    return ImageData(image)
                }.value
                guard let payload else {
                    try? await store.remove(id: item.id)
                    continue
                }
                let controller = makeController(
                    image: payload.cgImage,
                    id: item.id,
                    restoredFrame: item.frame
                )
                pins.append(controller)
                controller.show(takeKey: false)
            }
            NotificationCenter.default.post(name: .snipboPinsDidChange, object: nil)
        }
    }

    func pin(_ image: CGImage) {
        let id = UUID()
        let controller = makeController(image: image, id: id, restoredFrame: nil)
        pins.append(controller)
        controller.show()
        NotificationCenter.default.post(name: .snipboPinsDidChange, object: nil)

        let frame = controller.window?.frame ?? .zero
        Task { [store] in
            do {
                _ = try await store.save(image: image, id: id, frame: frame)
            } catch {
                NSLog("Snipbo: could not persist the pin: \(error.localizedDescription)")
            }
        }
    }

    /// Closes every live pin (context menu → "Close All"). Closing deletes
    /// each persisted file through `pinClosed`.
    func closeAll() {
        for controller in pins {
            controller.window?.close()
        }
    }

    var hasPins: Bool { !pins.isEmpty }

    func managedPins() -> [ManagedPin] {
        pins.enumerated().compactMap { index, controller in
            guard let window = controller.window else { return nil }
            let size = window.frame.size
            return ManagedPin(
                id: controller.id,
                title: "\(index + 1) · \(Int(size.width.rounded()))×\(Int(size.height.rounded()))"
            )
        }
    }

    func showPin(id: UUID) {
        guard let controller = pins.first(where: { $0.id == id }) else { return }
        controller.window?.orderFrontRegardless()
        controller.window?.makeKey()
    }

    func closePin(id: UUID) {
        pins.first(where: { $0.id == id })?.window?.close()
    }

    private func makeController(
        image: CGImage,
        id: UUID,
        restoredFrame: CGRect?
    ) -> PinWindowController {
        PinWindowController(
            image: image,
            id: id,
            restoredFrame: restoredFrame,
            onClose: { [weak self] closedID in
                self?.pinClosed(closedID)
            },
            onFrameChange: { [weak self] changedID, frame in
                self?.frameChanged(id: changedID, frame: frame)
            }
        )
    }

    private func pinClosed(_ id: UUID) {
        pins.removeAll { $0.id == id }
        pendingFrames.removeValue(forKey: id)
        Task { [store] in
            do {
                try await store.remove(id: id)
            } catch {
                NSLog("Snipbo: could not remove the persisted pin: \(error.localizedDescription)")
            }
        }
        NotificationCenter.default.post(name: .snipboPinsDidChange, object: nil)
    }

    /// Debounces move/resize updates so dragging a pin writes the index once
    /// after the gesture settles instead of on every frame.
    private func frameChanged(id: UUID, frame: CGRect) {
        pendingFrames[id] = frame
        frameSaveTask?.cancel()
        frameSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            let pending = self.pendingFrames
            self.pendingFrames.removeAll()
            for (pendingID, pendingFrame) in pending {
                try? await self.store.updateFrame(id: pendingID, frame: pendingFrame)
            }
        }
    }
}

@MainActor
final class PinWindowController: NSWindowController, NSWindowDelegate {
    let id: UUID
    private let image: CGImage
    private let onClose: (UUID) -> Void
    private let onFrameChange: (UUID, CGRect) -> Void

    init(
        image: CGImage,
        id: UUID,
        restoredFrame: CGRect?,
        onClose: @escaping (UUID) -> Void,
        onFrameChange: @escaping (UUID, CGRect) -> Void
    ) {
        self.image = image
        self.id = id
        self.onClose = onClose
        self.onFrameChange = onFrameChange

        let content = PinContentView(image: image)
        let panel = PinPanel(
            contentRect: restoredFrame.map(Self.clampedFrame) ?? Self.initialFrame(for: image),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = content
        panel.isMovableByWindowBackground = true
        super.init(window: panel)
        panel.delegate = self
        // True always-on-top: above every app's normal windows, visible on
        // all Spaces (and beside fullscreen windows), never hidden when the
        // app deactivates. Without the level bump the panel sits at .normal
        // and sinks behind other apps on first switch.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(takeKey: Bool = true) {
        // Order front without activating the app — pinning must never steal
        // focus from whatever the user is doing (Shottr-style). Restored pins
        // also skip makeKey so launch does not pull focus.
        window?.orderFrontRegardless()
        if takeKey {
            window?.makeKey()
            window?.makeFirstResponder(window?.contentView)
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClose(id)
    }

    func windowDidMove(_ notification: Notification) {
        guard let frame = window?.frame else { return }
        onFrameChange(id, frame)
    }

    func windowDidResize(_ notification: Notification) {
        guard let frame = window?.frame else { return }
        onFrameChange(id, frame)
    }

    private static func initialFrame(for image: CGImage) -> CGRect {
        // Fit within half of the visible screen, keeping the aspect ratio.
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var width = CGFloat(image.width)
        var height = CGFloat(image.height)
        let maxWidth = screen.width / 2
        let maxHeight = screen.height / 2
        if width > maxWidth || height > maxHeight {
            let scale = min(maxWidth / width, maxHeight / height)
            width *= scale
            height *= scale
        }
        // Cascade new pins down-right from the top-left corner.
        let offset = CGFloat(PinBoard.shared.pinCount % 6) * 28
        let origin = CGPoint(
            x: screen.minX + 60 + offset,
            y: screen.maxY - height - 80 - offset
        )
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    /// Keeps a restored pin on a currently connected display. A frame that no
    /// longer intersects a screen falls back to the main screen's visible area.
    private static func clampedFrame(_ frame: CGRect) -> CGRect {
        let screen = NSScreen.screens.first {
            $0.visibleFrame.intersects(frame.insetBy(dx: 20, dy: 20))
        } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return frame }
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        let x = min(max(frame.minX, visible.minX), visible.maxX - width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

private extension PinBoard {
    /// Exposed for the cascade offset; counts live pins.
    var pinCount: Int { pins.count }
}

/// Borderless, always-on-top, join-all-spaces pin window.
@MainActor
private final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Draws the pinned image and handles drag-to-move, wheel-to-resize,
/// Cmd+C and Esc.
@MainActor
private final class PinContentView: NSView {
    private let image: CGImage
    private var dragOutOrigin: CGPoint?
    private var dragOutTemporaryFile: URL?

    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
        // Borderless panels have no close affordance, so right-click offers
        // one; these work regardless of key status.
        let menu = NSMenu()
        let copyItem = NSMenuItem(
            title: L10n.tr("Copy (⌘C)", "复制 (⌘C)"),
            action: #selector(copyImageAction),
            keyEquivalent: ""
        )
        copyItem.target = self
        menu.addItem(copyItem)
        menu.addItem(.separator())
        let closeItem = NSMenuItem(
            title: L10n.tr("Close (Esc)", "关闭 (Esc)"),
            action: #selector(closeAction),
            keyEquivalent: ""
        )
        closeItem.target = self
        menu.addItem(closeItem)
        let closeAllItem = NSMenuItem(
            title: L10n.tr("Close All Pins", "关闭全部贴图"),
            action: #selector(closeAllAction),
            keyEquivalent: ""
        )
        closeAllItem.target = self
        menu.addItem(closeAllItem)
        self.menu = menu
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        DesignTokens.Color.canvasBase.setFill()
        bounds.fill()
        NSImage(cgImage: image, size: bounds.size).draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [NSImageRep.HintKey.interpolation: NSImageInterpolation.high.rawValue]
        )
    }

    override func scrollWheel(with event: NSEvent) {
        guard let window else { return }
        let factor = 1 - event.scrollingDeltaY * 0.0015
        let width = max(64, window.frame.width * factor)
        let height = window.frame.height * (width / window.frame.width)
        // Keep the pin's top-left corner fixed while resizing.
        let topLeft = CGPoint(x: window.frame.minX, y: window.frame.maxY)
        window.setFrame(window.frame.anchorTo(topLeft: topLeft, width: width, height: height), display: true)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" {
            copyImage()
            return
        }
        if event.keyCode == 53 {
            window?.close()
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking the pin makes it the key window again (without activating
        // the app), so ⌘C and Esc keep working after other windows had focus.
        window?.makeKey()
        window?.makeFirstResponder(self)
        // Option-drag exports the pin; a plain drag still moves the panel.
        if event.modifierFlags.contains(.option) {
            dragOutOrigin = convert(event.locationInWindow, from: nil)
        } else {
            dragOutOrigin = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOutOrigin else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - origin.x, point.y - origin.y) >= 4 else { return }
        dragOutOrigin = nil
        beginImageDrag(with: event, from: origin)
    }

    override func mouseUp(with event: NSEvent) {
        dragOutOrigin = nil
        super.mouseUp(with: event)
    }

    private func beginImageDrag(with event: NSEvent, from origin: CGPoint) {
        guard let payload = ImageDragSupport.makePayload(
            image: image,
            suggestedName: CaptureFileSaver.defaultFileName(format: .png)
        ) else {
            NSSound.beep()
            return
        }
        let frame = NSRect(
            x: origin.x - payload.preview.size.width / 2,
            y: origin.y - payload.preview.size.height / 2,
            width: payload.preview.size.width,
            height: payload.preview.size.height
        )
        payload.item.setDraggingFrame(frame, contents: payload.preview)
        dragOutTemporaryFile = payload.temporaryFile
        let session = beginDraggingSession(with: [payload.item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    private func copyImage() {
        let payload = ImageData(image)
        Task {
            let data = await Task.detached(priority: .userInitiated) {
                ImageExporter.pngData(from: payload.cgImage)
            }.value
            guard let data else {
                NSSound.beep()
                return
            }
            _ = PasteboardWriter.writePNG(data, to: NSPasteboard.general)
        }
    }

    @objc private func copyImageAction() { copyImage() }

    @objc private func closeAction() {
        window?.close()
    }

    @objc private func closeAllAction() {
        PinBoard.shared.closeAll()
    }
}

extension PinContentView: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        ImageDragSupport.removeTemporaryFile(dragOutTemporaryFile)
        dragOutTemporaryFile = nil
    }
}

private extension CGRect {
    /// A frame of the given size keeping this rect's top-left corner.
    func anchorTo(topLeft: CGPoint, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: topLeft.x, y: topLeft.y - height, width: width, height: height)
    }
}
