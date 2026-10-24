import AppKit

/// Small floating controls shown while the stream is running. The stream
/// excludes Snipbo's own windows, so this panel never appears in the result.
@MainActor
private final class ScrollingControlPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class ScrollingControlController {
    private let panel: ScrollingControlPanel
    private let label = NSTextField(labelWithString: L10n.tr("Scrolling… 0 px", "滚动中… 0 px"))
    private var shownHeight = 0
    private var keyMonitor: Any?
    private let onStop: () -> Void
    private let onCancel: () -> Void

    init(onStop: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onStop = onStop
        self.onCancel = onCancel

        let size = CGSize(width: 280, height: 64)
        let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSEvent.mouseLocation)
        }) ?? NSScreen.main
        let frame = CGRect(
            x: (screen?.frame.midX ?? 0) - size.width / 2,
            y: (screen?.frame.minY ?? 0) + 40,
            width: size.width,
            height: size.height
        )
        panel = ScrollingControlPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false

        let content = NSView(frame: CGRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        content.layer?.cornerRadius = 12

        label.textColor = .white
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)

        let stop = NSButton(title: L10n.tr("Stop", "停止"), target: self, action: #selector(stopAction))
        stop.bezelStyle = .rounded
        stop.controlSize = .small
        stop.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stop)

        let cancel = NSButton(title: L10n.tr("Cancel", "取消"), target: self, action: #selector(cancelAction))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .small
        cancel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(cancel)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cancel.leadingAnchor, constant: -10),
            cancel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            cancel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stop.trailingAnchor.constraint(equalTo: cancel.leadingAnchor, constant: -6),
            stop.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        panel.contentView = content
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event }
            self.onCancel()
            return nil
        }
    }

    func update(height: Int) {
        // Frame-processing hops can arrive out of order; never move the label
        // backwards.
        guard height > shownHeight else { return }
        shownHeight = height
        label.stringValue = L10n.tr("Scrolling… \(height) px", "滚动中… \(height) px")
    }

    func close() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        panel.orderOut(nil)
    }

    @objc private func stopAction() { onStop() }
    @objc private func cancelAction() { onCancel() }
}
