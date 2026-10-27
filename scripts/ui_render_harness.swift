import AppKit
import SnipboCore

// UI render harness: renders every surface touched by the HUD/capsule/token
// commits to PNGs under /tmp/snipbo-ui for visual review. Follows the same
// compile-and-run pattern as run_editor_probe.sh.

@main
struct UIRenderHarness {
    static func main() {
        _ = NSApplication.shared
        // The app pins itself to darkAqua (AppDelegate.applyAppearance); the
        // harness mirrors that so system-styled controls render as they will
        // in the real app.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await runAll()
            done.signal()
        }
        while done.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        exit(0)
    }

    @MainActor
    static func runAll() async {
        // Optional argv[1] overrides the output directory, so the same harness
        // can render a pre-change worktree for before/after comparisons.
        let dir = URL(
            fileURLWithPath: CommandLine.arguments.count > 1
                ? CommandLine.arguments[1] : "/tmp/snipbo-ui"
        )
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        await renderRecordingHUD(to: dir)
        await renderScrollingHUD(to: dir)
        await renderCountdown(to: dir)
        renderEditorToolbar(to: dir)
        renderRecognitionPanel(to: dir)
        await renderHistory(to: dir)
        print("ui-render done")
    }

    // MARK: Surfaces

    @MainActor
    static func renderRecordingHUD(to dir: URL) async {
        let controller = RecordingControlController(format: .mp4, onStop: {}, onCancel: {})
        controller.show()
        await spin(0.6)
        renderWindow(width: 300, height: 64, to: dir.appendingPathComponent("recording-hud.png"))
    }

    @MainActor
    static func renderScrollingHUD(to dir: URL) async {
        let controller = ScrollingControlController(autoScroll: true, onStop: {}, onCancel: {})
        controller.show()
        controller.update(height: 1846)
        await spin(0.3)
        renderWindow(width: 300, height: 80, to: dir.appendingPathComponent("scrolling-hud.png"))
    }

    @MainActor
    static func renderCountdown(to dir: URL) async {
        let controller = CountdownController(seconds: 3, onFinished: {}, onCancel: {})
        controller.start()
        await spin(0.3)
        renderWindow(width: 160, height: 120, to: dir.appendingPathComponent("countdown.png"))
        controller.cancel()
    }

    @MainActor
    static func renderEditorToolbar(to dir: URL) {
        let toolbar = EditorToolbarView(
            onTool: { _ in }, onUndo: {}, onRedo: {}, onRedact: { _ in },
            onRecognize: {}, onPin: {}, onCopy: {}, onSave: {}, onShowOptions: {}
        )
        toolbar.setSelectedTool(.rectangle)
        toolbar.updateReadouts(size: CGSize(width: 2022, height: 5175), zoom: 0.35)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: EditorToolbarView.height),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = toolbar
        renderContentView(of: window, to: dir.appendingPathComponent("editor-toolbar.png"))
    }

    @MainActor
    static func renderRecognitionPanel(to dir: URL) {
        let result = RecognitionResult(
            textBlocks: [
                TextBlock(
                    text: "Quarterly Report — Q3 2026",
                    boundingBox: CGRect(x: 0.08, y: 0.82, width: 0.62, height: 0.09),
                    confidence: 0.98
                ),
                TextBlock(
                    text: "Revenue grew 24.8% year over year, driven by",
                    boundingBox: CGRect(x: 0.08, y: 0.62, width: 0.84, height: 0.07),
                    confidence: 0.96
                ),
                TextBlock(
                    text: "subscription renewals and expanded seat usage.",
                    boundingBox: CGRect(x: 0.08, y: 0.50, width: 0.80, height: 0.07),
                    confidence: 0.95
                ),
            ],
            barcodes: [
                BarcodeResult(
                    payload: "https://example.com/reports/q3",
                    symbology: "QR",
                    boundingBox: CGRect(x: 0.7, y: 0.7, width: 0.2, height: 0.2)
                )
            ]
        )
        let panel = RecognitionResultsView(frame: NSRect(x: 0, y: 0, width: 280, height: 240))
        panel.show(result, removeLineBreaks: false)
        renderView(panel, to: dir.appendingPathComponent("recognition-panel.png"))
    }

    @MainActor
    static func renderHistory(to dir: URL) async {
        let storeDir = URL(fileURLWithPath: "/tmp/snipbo-ui-history-store")
        try? FileManager.default.removeItem(at: storeDir)
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let store = HistoryStore(
            baseDirectory: storeDir,
            maxItems: 50,
            maxBytes: 10 * 1024 * 1024
        )
        let samples: [(CGFloat, CaptureSource)] = [
            (0.58, .region), (0.34, .window), (0.80, .fullScreen),
            (0.12, .scrolling), (0.45, .region), (0.66, .window),
        ]
        for (index, sample) in samples.enumerated() {
            let image = makeSampleImage(
                width: 800 + index * 40, height: 520,
                hue: sample.0
            )
            do {
                _ = try await store.record(image: ImageData(image), source: sample.1)
            } catch {
                print("history sample \(index): \(error)")
            }
        }
        let browser = HistoryBrowserWindowController(store: store, openInEditor: { _ in })
        browser.showWindow(nil)
        await spin(0.8)
        if let window = browser.window {
            renderContentView(of: window, to: dir.appendingPathComponent("history.png"))
        } else {
            print("history: no window")
        }
    }

    // MARK: Helpers

    @MainActor
    static func renderWindow(width: CGFloat, height: CGFloat, to url: URL) {
        // An inactive accessory app's windows can be ordered but never
        // composited, so visibility is not a reliable filter here; cacheDisplay
        // works either way. Recording and scrolling HUDs share the width, so
        // the height disambiguates.
        guard let window = NSApp.windows.first(where: {
            // The HUD panels frame a 300pt content inset by margins, so match
            // on the content height, which is exact per surface.
            abs($0.frame.height - height) < 1
        }) else {
            print("no window \(Int(width))x\(Int(height)) for \(url.lastPathComponent)")
            return
        }
        renderContentView(of: window, to: url)
    }

    @MainActor
    static func renderContentView(of window: NSWindow, to url: URL) {
        guard let content = window.contentView else {
            print("no contentView for \(url.lastPathComponent)")
            return
        }
        renderView(content, to: url)
    }

    @MainActor
    static func renderView(_ view: NSView, to url: URL) {
        let rect = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else {
            print("no bitmap rep for \(url.lastPathComponent)")
            return
        }
        // Offscreen cacheDisplay resolves SwiftUI control bezels from
        // NSAppearance.current, not the view's effective appearance; without
        // this the filter-bar pickers draw as light pills. The real app draws
        // on screen under the pinned darkAqua, so this only fixes the harness.
        let previous = NSAppearance.current
        NSAppearance.current = NSApp.appearance
        defer { NSAppearance.current = previous }
        view.cacheDisplay(in: rect, to: rep)
        do {
            let data = try rep.representation(using: .png, properties: [:])
            try data?.write(to: url)
            print("\(url.lastPathComponent): \(Int(rect.width))x\(Int(rect.height))")
        } catch {
            print("write \(url.lastPathComponent): \(error)")
        }
    }

    @MainActor
    static func makeSampleImage(width: Int, height: Int, hue: CGFloat) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let colors = [
            NSColor(hue: hue, saturation: 0.42, brightness: 0.96, alpha: 1).cgColor,
            NSColor(hue: hue + 0.07, saturation: 0.32, brightness: 0.62, alpha: 1).cgColor,
        ] as CFArray
        let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(
            gradient, start: .zero,
            end: CGPoint(x: width, y: height), options: []
        )
        // A light strip reads as a captured window's title bar in thumbnails.
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.fill(CGRect(x: 0, y: height - 56, width: width, height: 56))
        return ctx.makeImage()!
    }

    @MainActor
    static func spin(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
