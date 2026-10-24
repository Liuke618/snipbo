import AppKit
import SnipboCore

/// Owns the floating pin windows. Pins are draggable, wheel-resizable,
/// always-on-top screenshots; Cmd+C copies and Esc closes. Pins are not
/// recorded to history.
@MainActor
final class PinBoard {
    static let shared = PinBoard()

    private var pins: [PinWindowController] = []

    private init() {}

    func pin(_ image: CGImage) {
        let id = UUID()
        let controller = PinWindowController(image: image, id: id) { [weak self] closedID in
            self?.pins.removeAll { $0.id == closedID }
        }
        pins.append(controller)
        controller.show()
    }

    /// Closes every live pin (context menu → "Close All").
    func closeAll() {
        for controller in pins {
            controller.window?.close()
        }
    }
}

@MainActor
final class PinWindowController: NSWindowController, NSWindowDelegate {
    let id: UUID
    private let image: CGImage
    private let onClose: (UUID) -> Void

    init(image: CGImage, id: UUID, onClose: @escaping (UUID) -> Void) {
        self.image = image
        self.id = id
        self.onClose = onClose

        let content = PinContentView(image: image)
        let panel = PinPanel(
            contentRect: Self.initialFrame(for: image),
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

    func show() {
        // Order front and take key without activating the app — pinning must
        // never steal focus from whatever the user is doing (Shottr-style).
        window?.orderFrontRegardless()
        window?.makeKey()
        window?.makeFirstResponder(window?.contentView)
    }

    func windowWillClose(_ notification: Notification) {
        onClose(id)
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
        NSColor.windowBackgroundColor.setFill()
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
    }

    private func copyImage() {
        guard let data = ImageExporter.pngData(from: image) else { return }
        _ = PasteboardWriter.writePNG(data, to: NSPasteboard.general)
    }

    @objc private func copyImageAction() { copyImage() }

    @objc private func closeAction() {
        window?.close()
    }

    @objc private func closeAllAction() {
        PinBoard.shared.closeAll()
    }
}

private extension CGRect {
    /// A frame of the given size keeping this rect's top-left corner.
    func anchorTo(topLeft: CGPoint, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: topLeft.x, y: topLeft.y - height, width: width, height: height)
    }
}
