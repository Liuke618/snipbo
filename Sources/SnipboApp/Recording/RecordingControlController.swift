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

        // The bar floats over arbitrary screen content, so its plate is a fixed
        // dark fill rather than a material: inside a transparent borderless panel
        // a material has nothing to blur and renders as an opaque plate that is
        // light in the light appearance. The fixed plate keeps the white label,
        // pill and cancel text readable under any system appearance.
        let content = NSView(frame: CGRect(origin: .zero, size: size))
        let background = HudBackgroundView(cornerRadius: DesignTokens.Radius.hud)
        content.addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            background.topAnchor.constraint(equalTo: content.topAnchor),
            background.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let dot = NSView(frame: CGRect(x: 14, y: 27, width: 9, height: 9))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4.5
        content.addSubview(dot)

        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        // A label that cannot fit the bar ends with "…" rather than being cut
        // off under the Stop pill.
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        updateLabel()

        let stop = PillButton(
            title: L10n.tr("Stop", "停止"),
            target: self,
            action: #selector(stopAction)
        )
        stop.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stop)

        let cancel = PillButton(
            title: L10n.tr("Cancel", "取消"),
            target: self,
            action: #selector(cancelAction),
            style: .plain
        )
        cancel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(cancel)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            // Bound to the Stop pill rather than to Cancel: the capsule sits in
            // front of the label, so a long localized string truncates with "…"
            // before it instead of being clipped by the pill.
            label.trailingAnchor.constraint(lessThanOrEqualTo: stop.leadingAnchor, constant: -10),
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
