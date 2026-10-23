import AppKit
import LightShotCore

/// A small floating countdown that closes itself before the capture starts, so
/// it can never appear in the resulting screenshot.
@MainActor
final class CountdownController {
    private let window: SelectionOverlayWindow
    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var keyMonitor: Any?
    private var countdown: Countdown
    private let onFinished: () -> Void
    private let onCancel: () -> Void

    init(seconds: Int, onFinished: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.countdown = Countdown(seconds: seconds)
        self.onFinished = onFinished
        self.onCancel = onCancel

        let size = CGSize(width: 160, height: 120)
        let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSEvent.mouseLocation)
        }) ?? NSScreen.main
        let frame = CGRect(
            x: (screen?.frame.midX ?? 0) - size.width / 2,
            y: (screen?.frame.maxY ?? size.height) - size.height - 80,
            width: size.width,
            height: size.height
        )
        window = SelectionOverlayWindow(screenFrame: frame)

        let content = NSView(frame: CGRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        content.layer?.cornerRadius = 18

        label.frame = content.bounds
        label.autoresizingMask = [.width, .height]
        label.alignment = .center
        label.font = .monospacedDigitSystemFont(ofSize: 56, weight: .semibold)
        label.textColor = .white
        label.stringValue = countdown.label
        content.addSubview(label)
        window.contentView = content
    }

    func start() {
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKey()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.keyCode == 53 else { return event }
            self.cancel()
            return nil
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    private func tick() {
        guard timer != nil else { return }
        if countdown.tick() {
            finish()
        } else {
            label.stringValue = countdown.label
        }
    }

    private func finish() {
        stop()
        onFinished()
    }

    private func cancel() {
        stop()
        onCancel()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        window.orderOut(nil)
    }
}
