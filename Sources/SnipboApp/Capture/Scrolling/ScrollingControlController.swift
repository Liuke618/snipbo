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
    private let autoScroll: Bool
    private var shownHeight = 0
    private var keyMonitor: Any?
    private let onStop: () -> Void
    private let onCancel: () -> Void

    init(
        autoScroll: Bool = false,
        onStop: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onStop = onStop
        self.onCancel = onCancel
        self.autoScroll = autoScroll
        if autoScroll {
            label.stringValue = L10n.tr("Auto-scrolling… 0 px", "自动滚动中… 0 px")
        }

        let size = CGSize(width: 300, height: autoScroll ? 80 : 64)
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

        // The bar floats over arbitrary screen content, so its plate is a fixed
        // dark fill rather than a material: inside a transparent borderless panel
        // a material has nothing to blur and renders as an opaque plate that is
        // light in the light appearance. The fixed plate keeps the white label,
        // pill, cancel text and hint readable under any system appearance.
        let content = NSView(frame: CGRect(origin: .zero, size: size))
        let background = HudBackgroundView(cornerRadius: DesignTokens.Radius.hud)
        content.addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            background.topAnchor.constraint(equalTo: content.topAnchor),
            background.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        label.textColor = .white
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        // A label that cannot fit the bar ends with "…" rather than being cut
        // off under the Stop pill.
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)

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

        let hint = NSTextField(labelWithString: L10n.tr(
            "Keep the pointer over the content",
            "请把指针放在要滚动的内容上"
        ))
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = NSColor.white.withAlphaComponent(0.65)
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.isHidden = !autoScroll
        content.addSubview(hint)

        var constraints = [
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            // Bound to the Stop pill rather than to Cancel: the capsule sits in
            // front of the label, so a long localized string truncates with "…"
            // before it instead of being clipped by the pill.
            label.trailingAnchor.constraint(lessThanOrEqualTo: stop.leadingAnchor, constant: -10),
            cancel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            cancel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stop.trailingAnchor.constraint(equalTo: cancel.leadingAnchor, constant: -6),
            stop.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            hint.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: cancel.leadingAnchor, constant: -10),
        ]
        if autoScroll {
            constraints.append(contentsOf: [
                label.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
                hint.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
            ])
        } else {
            constraints.append(label.centerYAnchor.constraint(equalTo: content.centerYAnchor))
        }
        NSLayoutConstraint.activate(constraints)
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
        label.stringValue = autoScroll
            ? L10n.tr("Auto-scrolling… \(height) px", "自动滚动中… \(height) px")
            : L10n.tr("Scrolling… \(height) px", "滚动中… \(height) px")
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
