import AppKit
import SnipboCore

@MainActor
private final class RecordingControlPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Floating stop/cancel bar shown while a recording runs. It deliberately does
/// not activate Snipbo: the app being recorded must keep focus.
@MainActor
final class RecordingControlController {
    private let panel: RecordingControlPanel
    private let label = NSTextField(labelWithString: "")
    private let format: RecordingFormat
    private let startedAt = Date()
    private var timer: Timer?
    private let onStop: () -> Void
    private let onCancel: () -> Void

    init(
        format: RecordingFormat,
        onStop: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.format = format
        self.onStop = onStop
        self.onCancel = onCancel

        let size = CGSize(width: 300, height: 64)
        let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSEvent.mouseLocation)
        }) ?? NSScreen.main
        let frame = CGRect(
            x: (screen?.frame.midX ?? 0) - size.width / 2,
            y: (screen?.frame.minY ?? 0) + 40,
            width: size.width,
            height: size.height
        )
        panel = RecordingControlPanel(
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

        let dot = NSView(frame: CGRect(x: 14, y: 27, width: 9, height: 9))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4.5
        content.addSubview(dot)

        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        updateLabel()

        let stop = NSButton(
            title: L10n.tr("Stop", "停止"),
            target: self,
            action: #selector(stopAction)
        )
        stop.bezelStyle = .rounded
        stop.controlSize = .small
        stop.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stop)

        let cancel = NSButton(
            title: L10n.tr("Cancel", "取消"),
            target: self,
            action: #selector(cancelAction)
        )
        cancel.bezelStyle = .rounded
        cancel.controlSize = .small
        cancel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(cancel)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
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
        // No NSApp.activate: recording must not steal focus from the target app.
        // Making the nonactivating panel key lets its buttons receive clicks
        // without activating Snipbo.
        panel.orderFrontRegardless()
        panel.makeKey()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
            [weak self] _ in
            self?.updateLabel()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func close() {
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
    }

    private func updateLabel() {
        let elapsed = max(0, Int(Date().timeIntervalSince(startedAt)))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        let kind = format == .mp4 ? "MP4" : "GIF"
        label.stringValue = L10n.tr(
            "Recording… \(String(format: "%02d:%02d", minutes, seconds)) · \(kind)",
            "录制中… \(String(format: "%02d:%02d", minutes, seconds)) · \(kind)"
        )
    }

    @objc private func stopAction() { onStop() }
    @objc private func cancelAction() { onCancel() }
}
