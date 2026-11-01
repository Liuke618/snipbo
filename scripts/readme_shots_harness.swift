import AppKit
import CoreText
import SnipboCore

// README shot harness: renders the four screenshots embedded in README.md
// (editor, capture, recognition, settings) offscreen from the live UI code.
// Screen Recording TCC blocks real screen grabs from a probe, so every
// surface goes through cacheDisplay; the Pulse demo dashboard and the staged
// desktop behind the capture shot are drawn with CoreGraphics, keeping the
// shots reproducible without binary assets or a second machine.
//
//   scripts/run_readme_shots.sh [outdir]

@main
struct ReadmeShotsHarness {
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
        let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1
            ? CommandLine.arguments[1] : "/tmp/snipbo-readme")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let dashboard = makeDashboard()
        write(dashboard, to: dir.appendingPathComponent("dashboard.png"))
        await renderEditorShot(to: dir, dashboard: dashboard, recognition: false)
        await renderEditorShot(to: dir, dashboard: dashboard, recognition: true)
        renderCaptureShot(to: dir, dashboard: dashboard)
        renderSettingsShot(to: dir)
        print("readme-shots done")
    }

    // MARK: - Editor / recognition shots

    @MainActor
    static func renderEditorShot(to dir: URL, dashboard: CGImage, recognition: Bool) async {
        let name = recognition ? "recognition" : "editor"
        let editor = EditorWindowController(
            document: EditDocument(image: dashboard),
            settingsProvider: { AppSettings.default },
            history: HistoryStore(
                baseDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("snipbo-readme-history", isDirectory: true),
                maxItems: 4,
                maxBytes: 64 * 1024 * 1024
            ),
            onClose: {}
        )
        editor.show()
        runTicks(6)
        editor.window?.setContentSize(NSSize(width: 1560, height: 1080))
        editor.fitToWindow()
        addSampleAnnotations(to: editor.controller)
        // The style panel shows for a drawing tool, matching the state after
        // the arrow was drawn.
        editor.controller.tool = .arrow
        runTicks(4)

        if recognition {
            await attachRecognitionPanel(to: editor, image: dashboard)
            runTicks(4)
        }

        editor.window?.orderFrontRegardless()
        runTicks(4)
        guard let window = editor.window, let themeFrame = window.contentView?.superview else {
            print("\(name): no window")
            editor.close()
            return
        }
        let rep = renderToRep(themeFrame)
        let backdrop = NSSize(width: 1680, height: 1160)
        composite(rep, window: window, backdropSize: backdrop,
                  to: dir.appendingPathComponent("\(name).png"))
        editor.close()
    }

    @MainActor
    static func addSampleAnnotations(to controller: EditorController) {
        let red = RGBA(red: 1, green: 0, blue: 0, alpha: 1)
        let yellow = RGBA(red: 1, green: 0.84, blue: 0.1, alpha: 1)
        var style = AnnotationStyle()
        // Coordinates are dashboard pixels (2400×1500), top-down.

        style = AnnotationStyle(color: yellow, opacity: 0.55)
        append(controller, Annotation(
            kind: .highlight,
            geometry: .rect(CGRect(x: 1620, y: 520, width: 704, height: 92)),
            style: style, zIndex: 1
        ))

        style = AnnotationStyle(color: red, pixelBlockSize: 14)
        append(controller, Annotation(
            kind: .pixelate,
            geometry: .rect(CGRect(x: 480, y: 1072, width: 360, height: 56)),
            style: style, zIndex: 2
        ))

        style = AnnotationStyle(color: red, lineWidth: 8)
        append(controller, Annotation(
            kind: .ellipse,
            geometry: .rect(CGRect(x: 1112, y: 256, width: 210, height: 100)),
            style: style, zIndex: 3
        ))

        style = AnnotationStyle(color: red, fontSize: 38)
        append(controller, Annotation(
            kind: .counter,
            geometry: .badge(center: CGPoint(x: 1452, y: 306), value: 1),
            style: style, zIndex: 4
        ))

        append(controller, Annotation(
            kind: .text,
            geometry: .text(origin: CGPoint(x: 500, y: 610), width: 440, value: "Deploy at 14:02"),
            style: style, zIndex: 5
        ))

        style = AnnotationStyle(color: red, lineWidth: 9, arrowStyle: .tapered)
        append(controller, Annotation(
            kind: .arrow,
            geometry: .line(start: CGPoint(x: 760, y: 668), end: CGPoint(x: 1344, y: 742)),
            style: style, zIndex: 6
        ))
    }

    @MainActor
    static func append(_ controller: EditorController, _ annotation: Annotation) {
        controller.document.annotations.append(annotation)
    }

    @MainActor
    static func attachRecognitionPanel(to editor: EditorWindowController, image: CGImage) async {
        do {
            let result = try await RecognitionService.shared.recognize(
                ImageData(image),
                languages: ["en-US"]
            )
            guard !result.isEmpty else {
                print("recognition: nothing found")
                return
            }
            let panel = RecognitionResultsView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
            panel.onCopy = { _ in }
            panel.onClose = {}
            panel.show(result, removeLineBreaks: false)
            if let container = editor.stylePanelView?.superview ?? editor.window?.contentView {
                panel.translatesAutoresizingMaskIntoConstraints = false
                // The real editor adds the panel to the body view under the
                // floating chrome; hosting it in the style panel's own
                // superview keeps that z-order. The canvas does not shrink
                // here (the scroll view's trailing constraint is private), so
                // the panel starts below the floating style panel instead of
                // the chrome band, keeping its header readable.
                container.addSubview(panel, positioned: .below, relativeTo: editor.stylePanelView)
                var topOffset = EditorChromeView.topBandHeight + 8
                if let stylePanel = editor.stylePanelView {
                    let styleFrame = stylePanel.convert(stylePanel.bounds, to: container)
                    if styleFrame.minY > 0 {
                        topOffset = container.bounds.height - styleFrame.minY + 8
                    }
                }
                NSLayoutConstraint.activate([
                    panel.leadingAnchor.constraint(equalTo: container.trailingAnchor, constant: -300),
                    panel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    panel.topAnchor.constraint(equalTo: container.topAnchor, constant: topOffset),
                    panel.bottomAnchor.constraint(
                        equalTo: container.bottomAnchor,
                        constant: -(EditorChromeView.bottomBandHeight + 8)
                    ),
                ])
                // Mirror the real editor: the panel only appears once the
                // window lays out after the constraints activate.
                editor.window?.layoutIfNeeded()
            }
            // Vision boxes are relative to the rendered crop; the harness
            // uses the full image, so no crop offset applies.
            let textRects = result.textBlocks.map {
                $0.pixelRect(imageWidth: image.width, imageHeight: image.height)
            }
            let barcodeRects = result.barcodes.map {
                $0.pixelRect(imageWidth: image.width, imageHeight: image.height)
            }
            editor.canvasView.setRecognitionHighlights(textRects + barcodeRects)
            print("recognition: \(result.textBlocks.count) blocks, \(result.barcodes.count) barcodes")
        } catch {
            print("recognition failed: \(error)")
        }
    }

    // MARK: - Capture shot

    @MainActor
    static func renderCaptureShot(to dir: URL, dashboard: CGImage) {
        let scene = makeDesktopScene(dashboard: dashboard)
        write(scene, to: dir.appendingPathComponent("scene.png"))
        let captured = CapturedImage(
            image: scene,
            geometry: ScreenGeometry(
                displayID: 1,
                frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                backingScale: 2
            )
        )
        let overlay = SelectionOverlayView(captured: captured)
        overlay.selection = SelectionModel(rect: CGRect(x: 405, y: 295, width: 1020, height: 320))
        let rep = renderToRep(overlay)
        write(rep, to: dir.appendingPathComponent("capture.png"))
    }

    // MARK: - Settings shot

    @MainActor
    static func renderSettingsShot(to dir: URL) {
        let defaults = UserDefaults(suiteName: "local.snipbo.readme-shots") ?? .standard
        let controller = SettingsWindowController(model: SettingsModel(defaults: defaults))
        controller.show()
        runTicks(8)
        controller.window?.orderFrontRegardless()
        runTicks(4)
        guard let window = controller.window,
              let themeFrame = window.contentView?.superview else {
            print("settings: no window")
            return
        }
        let rep = renderToRep(themeFrame)
        let width = rep.size.width + 200
        let height = rep.size.height + 180
        composite(rep, window: window, backdropSize: NSSize(width: width, height: height),
                  to: dir.appendingPathComponent("settings.png"))
        window.close()
    }

    // MARK: - Window/view rendering

    @MainActor
    static func runTicks(_ count: Int) {
        for _ in 0..<count { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    @MainActor
    static func bitmapRep(width: CGFloat, height: CGFloat, scale: CGFloat) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = NSSize(width: width, height: height)
        return rep
    }

    /// Renders a view (including the window theme frame, so traffic lights
    /// come along) at 2x.
    @MainActor
    static func renderToRep(_ view: NSView) -> NSBitmapImageRep {
        let bounds = view.bounds
        let rep = bitmapRep(width: bounds.width, height: bounds.height, scale: 2)
        let previous = NSAppearance.current
        NSAppearance.current = NSApp.appearance
        view.cacheDisplay(in: bounds, to: rep)
        NSAppearance.current = previous
        return rep
    }

    /// Places a rendered window on the dark desktop backdrop the README uses,
    /// with a soft drop shadow. The harness windows are never key, so their
    /// traffic lights render gray; the real button frames are used to paint
    /// the colored caps over them.
    @MainActor
    static func composite(
        _ windowRep: NSBitmapImageRep, window: NSWindow?, backdropSize: NSSize, to url: URL
    ) {
        guard let windowCG = windowRep.cgImage else {
            print("composite \(url.lastPathComponent): no cg image")
            return
        }
        let wSize = windowRep.size
        let origin = CGPoint(
            x: (backdropSize.width - wSize.width) / 2,
            y: (backdropSize.height - wSize.height) / 2
        )
        let final = bitmapRep(width: backdropSize.width, height: backdropSize.height, scale: 2)
        guard let gctx = NSGraphicsContext(bitmapImageRep: final) else {
            print("composite \(url.lastPathComponent): no context")
            return
        }
        NSGraphicsContext.current = gctx
        let ctx = gctx.cgContext
        drawBackdropGradient(ctx, width: backdropSize.width, height: backdropSize.height)
        ctx.saveGState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 36
        // AppKit bottom-up space: a negative y offset throws the shadow down.
        shadow.shadowOffset = NSSize(width: 0, height: -14)
        shadow.set()
        let frame = NSRect(
            x: origin.x, y: backdropSize.height - origin.y - wSize.height,
            width: wSize.width, height: wSize.height
        )
        NSImage(cgImage: windowCG, size: wSize).draw(in: frame)
        ctx.restoreGState()
        if let window {
            paintTrafficLights(window: window, windowFrame: frame, onto: ctx)
        }
        NSGraphicsContext.current = nil
        write(final, to: url)
    }

    @MainActor
    static func paintTrafficLights(window: NSWindow, windowFrame: NSRect, onto ctx: CGContext) {
        guard let themeFrame = window.contentView?.superview else { return }
        let buttons: [(NSButton?, NSColor)] = [
            (window.standardWindowButton(.closeButton), rgb(0xFF5F57)),
            (window.standardWindowButton(.miniaturizeButton), rgb(0xFEBC2E)),
            (window.standardWindowButton(.zoomButton), rgb(0x28C840)),
        ]
        for (button, color) in buttons {
            guard let button, button.superview != nil else { continue }
            let rect = button.convert(button.bounds, to: themeFrame)
            let center = CGPoint(
                x: windowFrame.minX + rect.midX,
                y: windowFrame.minY + rect.midY
            )
            let radius = rect.width / 2 + 0.5
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            ))
        }
    }

    static func drawBackdropGradient(_ ctx: CGContext, width: CGFloat, height: CGFloat) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let gradient = CGGradient(
            colorsSpace: space,
            colors: [
                NSColor(srgbRed: 0.031, green: 0.047, blue: 0.090, alpha: 1).cgColor,
                NSColor(srgbRed: 0.086, green: 0.145, blue: 0.263, alpha: 1).cgColor,
                NSColor(srgbRed: 0.043, green: 0.067, blue: 0.125, alpha: 1).cgColor,
            ] as CFArray,
            locations: [0, 0.55, 1]
        )!
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: width, y: height),
            options: []
        )
    }

    // MARK: - CoreGraphics scene helpers (top-down coordinates)

    /// Creates an RGBA context, applies a uniform scale and flips to top-down
    /// coordinates, then hands it to `body`.
    static func flippedContext(
        width: CGFloat, height: CGFloat, scale: CGFloat,
        _ body: (CGContext) -> Void
    ) -> CGImage {
        let ctx = CGContext(
            data: nil, width: Int(width * scale), height: Int(height * scale),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)
        body(ctx)
        return ctx.makeImage()!
    }

    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    static func text(
        _ ctx: CGContext, _ string: String, size: CGFloat,
        weight: NSFont.Weight = .regular, color: NSColor,
        at point: CGPoint, tracking: CGFloat = 0
    ) {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if tracking != 0 { attrs[.kern] = tracking }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs))
        ctx.saveGState()
        ctx.translateBy(x: point.x, y: point.y + CTFontGetAscent(font))
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    static func textWidth(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular, tracking: CGFloat = 0) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        var attrs: [NSAttributedString.Key: Any] = [.font: font]
        if tracking != 0 { attrs[.kern] = tracking }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    static func textRight(
        _ ctx: CGContext, _ string: String, size: CGFloat,
        weight: NSFont.Weight = .regular, color: NSColor,
        rightX: CGFloat, y: CGFloat, tracking: CGFloat = 0
    ) {
        let w = textWidth(string, size: size, weight: weight, tracking: tracking)
        text(ctx, string, size: size, weight: weight, color: color,
             at: CGPoint(x: rightX - w, y: y), tracking: tracking)
    }

    static func textCentered(
        _ ctx: CGContext, _ string: String, size: CGFloat,
        weight: NSFont.Weight = .regular, color: NSColor,
        centerX: CGFloat, y: CGFloat, tracking: CGFloat = 0
    ) {
        let w = textWidth(string, size: size, weight: weight, tracking: tracking)
        text(ctx, string, size: size, weight: weight, color: color,
             at: CGPoint(x: centerX - w / 2, y: y), tracking: tracking)
    }

    static func rr(
        _ ctx: CGContext, _ rect: CGRect, _ radius: CGFloat,
        fill: NSColor? = nil, stroke: NSColor? = nil, lineWidth: CGFloat = 1
    ) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(path)
        if let fill {
            ctx.setFillColor(fill.cgColor)
            ctx.fillPath()
        }
        if let stroke {
            ctx.addPath(path)
            ctx.setStrokeColor(stroke.cgColor)
            ctx.setLineWidth(lineWidth)
            ctx.strokePath()
        }
    }

    static func fillRect(_ ctx: CGContext, _ rect: CGRect, _ color: NSColor) {
        ctx.setFillColor(color.cgColor)
        ctx.fill(rect)
    }

    static func strokePath(_ ctx: CGContext, _ draw: (CGMutablePath) -> Void, color: NSColor, width: CGFloat, dashed: Bool = false) {
        let path = CGMutablePath()
        draw(path)
        ctx.addPath(path)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if dashed { ctx.setLineDash(phase: 0, lengths: [9, 9]) }
        ctx.strokePath()
        if dashed { ctx.setLineDash(phase: 0, lengths: []) }
    }

    static func circle(_ ctx: CGContext, center: CGPoint, radius: CGFloat, fill: NSColor? = nil, stroke: NSColor? = nil, lineWidth: CGFloat = 1) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        if let fill {
            ctx.setFillColor(fill.cgColor)
            ctx.fillEllipse(in: rect)
        }
        if let stroke {
            ctx.setStrokeColor(stroke.cgColor)
            ctx.setLineWidth(lineWidth)
            ctx.strokeEllipse(in: rect)
        }
    }

    static func triangle(_ ctx: CGContext, apexTopMid: CGPoint, width: CGFloat, height: CGFloat, up: Bool, color: NSColor) {
        let path = CGMutablePath()
        if up {
            path.move(to: CGPoint(x: apexTopMid.x, y: apexTopMid.y))
            path.addLine(to: CGPoint(x: apexTopMid.x - width / 2, y: apexTopMid.y + height))
            path.addLine(to: CGPoint(x: apexTopMid.x + width / 2, y: apexTopMid.y + height))
        } else {
            path.move(to: CGPoint(x: apexTopMid.x, y: apexTopMid.y + height))
            path.addLine(to: CGPoint(x: apexTopMid.x - width / 2, y: apexTopMid.y))
            path.addLine(to: CGPoint(x: apexTopMid.x + width / 2, y: apexTopMid.y))
        }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
    }

    static func drawImage(_ ctx: CGContext, _ image: CGImage, in rect: CGRect) {
        // CGImage data is top-down; under the flipped CTM a plain draw(in:)
        // lands upside down, so counter-flip around the rect.
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    /// Simplified Apple menu glyph (the SF Pro private-use apple codepoint
    /// does not render through CoreText).
    static func drawAppleSilhouette(_ ctx: CGContext, center: CGPoint) {
        let w: CGFloat = 15, h: CGFloat = 17
        let top = CGPoint(x: center.x, y: center.y - h / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: top.x, y: top.y + 4))
        path.addCurve(
            to: CGPoint(x: top.x - w / 2, y: top.y + 6),
            control1: CGPoint(x: top.x - w * 0.3, y: top.y - 0.5),
            control2: CGPoint(x: top.x - w / 2, y: top.y + 2)
        )
        path.addCurve(
            to: CGPoint(x: top.x - w * 0.32, y: top.y + h - 1),
            control1: CGPoint(x: top.x - w / 2 - 1.5, y: top.y + 10),
            control2: CGPoint(x: top.x - w * 0.42, y: top.y + h)
        )
        path.addCurve(
            to: CGPoint(x: top.x, y: top.y + h - 2.5),
            control1: CGPoint(x: top.x - w * 0.2, y: top.y + h + 0.5),
            control2: CGPoint(x: top.x - w * 0.08, y: top.y + h - 1)
        )
        path.addCurve(
            to: CGPoint(x: top.x + w * 0.32, y: top.y + h - 1),
            control1: CGPoint(x: top.x + w * 0.08, y: top.y + h - 1),
            control2: CGPoint(x: top.x + w * 0.2, y: top.y + h + 0.5)
        )
        path.addCurve(
            to: CGPoint(x: top.x + w / 2, y: top.y + 6),
            control1: CGPoint(x: top.x + w * 0.42, y: top.y + h),
            control2: CGPoint(x: top.x + w / 2 + 1.5, y: top.y + 10)
        )
        path.addCurve(
            to: CGPoint(x: top.x, y: top.y + 4),
            control1: CGPoint(x: top.x + w / 2, y: top.y + 2),
            control2: CGPoint(x: top.x + w * 0.3, y: top.y - 0.5)
        )
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        ctx.fillPath()
        // Leaf.
        ctx.saveGState()
        ctx.translateBy(x: top.x + 3.2, y: top.y - 1)
        ctx.rotate(by: -0.6)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        ctx.fillEllipse(in: CGRect(x: -3, y: -1.8, width: 6, height: 3.6))
        ctx.restoreGState()
    }

    // MARK: - Pulse demo dashboard (2400×1500 px, top-down)

    static func makeDashboard() -> CGImage {
        flippedContext(width: 2400, height: 1500, scale: 1) { ctx in
            let W: CGFloat = 2400, H: CGFloat = 1500
            let clip = CGPath(roundedRect: CGRect(x: 0, y: 0, width: W, height: H), cornerWidth: 40, cornerHeight: 40, transform: nil)
            ctx.addPath(clip)
            ctx.clip()

            // Main surface + window title bar.
            fillRect(ctx, CGRect(x: 0, y: 0, width: W, height: H), .white)
            fillRect(ctx, CGRect(x: 0, y: 0, width: W, height: 56), rgb(0xF6F6F6))
            fillRect(ctx, CGRect(x: 0, y: 55, width: W, height: 1), rgb(0xE4E4E4))
            circle(ctx, center: CGPoint(x: 44, y: 28), radius: 13, fill: rgb(0xFF5F57), stroke: rgb(0xE0443E), lineWidth: 1)
            circle(ctx, center: CGPoint(x: 84, y: 28), radius: 13, fill: rgb(0xFEBC2E), stroke: rgb(0xDEA123), lineWidth: 1)
            circle(ctx, center: CGPoint(x: 124, y: 28), radius: 13, fill: rgb(0x28C840), stroke: rgb(0x1FAB33), lineWidth: 1)
            textCentered(ctx, "Pulse — Product Analytics", size: 26, weight: .medium, color: rgb(0x6E6E73), centerX: W / 2, y: 15)

            // Sidebar.
            fillRect(ctx, CGRect(x: 0, y: 56, width: 400, height: H - 56), rgb(0x16202F))
            circle(ctx, center: CGPoint(x: 74, y: 150), radius: 24, fill: rgb(0x35A3F1))
            circle(ctx, center: CGPoint(x: 74, y: 150), radius: 10, stroke: .white, lineWidth: 6)
            text(ctx, "Pulse", size: 32, weight: .semibold, color: rgb(0xE8EEF7), at: CGPoint(x: 116, y: 128))
            text(ctx, "ANALYTICS", size: 18, weight: .medium, color: rgb(0x8FA0BC), at: CGPoint(x: 116, y: 168), tracking: 2)

            text(ctx, "WORKSPACE", size: 18, weight: .medium, color: rgb(0x6E7F9C), at: CGPoint(x: 64, y: 262), tracking: 2)
            rr(ctx, CGRect(x: 40, y: 300, width: 320, height: 72), 12, fill: rgb(0x24344E))
            for (dx, dy) in [(0.0, 0.0), (18.0, 0.0), (0.0, 18.0), (18.0, 18.0)] {
                rr(ctx, CGRect(x: 66 + dx, y: 324 + dy, width: 13, height: 13), 3, fill: rgb(0xE8EEF7))
            }
            text(ctx, "Overview", size: 26, weight: .medium, color: rgb(0xE8EEF7), at: CGPoint(x: 116, y: 324))

            // Funnels
            strokePath(ctx, { p in
                p.move(to: CGPoint(x: 66, y: 404)); p.addLine(to: CGPoint(x: 98, y: 404)); p.addLine(to: CGPoint(x: 82, y: 428)); p.addLine(to: CGPoint(x: 82, y: 438))
            }, color: rgb(0x93A3BE), width: 4)
            text(ctx, "Funnels", size: 26, color: rgb(0x93A3BE), at: CGPoint(x: 116, y: 412))
            // Users
            circle(ctx, center: CGPoint(x: 82, y: 488), radius: 9, stroke: rgb(0x93A3BE), lineWidth: 4)
            strokePath(ctx, { p in
                p.move(to: CGPoint(x: 64, y: 524)); p.addQuadCurve(to: CGPoint(x: 100, y: 524), control: CGPoint(x: 82, y: 500))
            }, color: rgb(0x93A3BE), width: 4)
            text(ctx, "Users", size: 26, color: rgb(0x93A3BE), at: CGPoint(x: 116, y: 494))
            // Revenue
            fillRect(ctx, CGRect(x: 64, y: 586, width: 9, height: 18), rgb(0x93A3BE))
            fillRect(ctx, CGRect(x: 79, y: 576, width: 9, height: 28), rgb(0x93A3BE))
            fillRect(ctx, CGRect(x: 94, y: 562, width: 9, height: 42), rgb(0x93A3BE))
            text(ctx, "Revenue", size: 26, color: rgb(0x93A3BE), at: CGPoint(x: 116, y: 576))
            // Reports
            rr(ctx, CGRect(x: 68, y: 656, width: 28, height: 38), 6, stroke: rgb(0x93A3BE), lineWidth: 4)
            fillRect(ctx, CGRect(x: 76, y: 668, width: 14, height: 4), rgb(0x93A3BE))
            fillRect(ctx, CGRect(x: 76, y: 680, width: 14, height: 4), rgb(0x93A3BE))
            text(ctx, "Reports", size: 26, color: rgb(0x93A3BE), at: CGPoint(x: 116, y: 660))

            text(ctx, "MANAGE", size: 18, weight: .medium, color: rgb(0x6E7F9C), at: CGPoint(x: 64, y: 756), tracking: 2)
            circle(ctx, center: CGPoint(x: 82, y: 800), radius: 12, stroke: rgb(0x93A3BE), lineWidth: 4)
            circle(ctx, center: CGPoint(x: 82, y: 800), radius: 4, fill: rgb(0x93A3BE))
            text(ctx, "Settings", size: 26, color: rgb(0x93A3BE), at: CGPoint(x: 116, y: 788))

            circle(ctx, center: CGPoint(x: 86, y: 1330), radius: 28, fill: rgb(0x35A3F1))
            textCentered(ctx, "MC", size: 24, weight: .semibold, color: .white, centerX: 86, y: 1318)
            text(ctx, "Maya Chen", size: 24, color: rgb(0xE8EEF7), at: CGPoint(x: 136, y: 1308))
            text(ctx, "Growth team", size: 19, color: rgb(0x8FA0BC), at: CGPoint(x: 136, y: 1344))

            // Header.
            text(ctx, "Weekly product metrics", size: 44, weight: .bold, color: rgb(0x0F1B2D), at: CGPoint(x: 456, y: 110))
            text(ctx, "Oct 26 – Nov 1, 2026 · All channels · compared to previous week", size: 24, color: rgb(0x7C8AA0), at: CGPoint(x: 456, y: 174))

            rr(ctx, CGRect(x: 1876, y: 108, width: 154, height: 56), 12, fill: rgb(0xF1F4F8))
            strokePath(ctx, { p in
                p.move(to: CGPoint(x: 1906, y: 128)); p.addLine(to: CGPoint(x: 1906, y: 142)); p.addLine(to: CGPoint(x: 1900, y: 136))
                p.move(to: CGPoint(x: 1906, y: 142)); p.addLine(to: CGPoint(x: 1912, y: 136))
            }, color: rgb(0x33415C), width: 3)
            text(ctx, "Export", size: 24, weight: .medium, color: rgb(0x33415C), at: CGPoint(x: 1930, y: 122))
            rr(ctx, CGRect(x: 2054, y: 108, width: 146, height: 56), 12, fill: rgb(0x1D3050))
            textCentered(ctx, "Share", size: 24, weight: .semibold, color: .white, centerX: 2127, y: 122)

            // Stat cards.
            let cards: [(x: CGFloat, label: String, value: String, delta: String, up: Bool, deltaColor: NSColor, sub: String)] = [
                (456, "WEEKLY ACTIVE USERS", "48,210", "12.4%", true, rgb(0x1FA97C), "41,918 last week"),
                (1093, "CONVERSION RATE", "3.82%", "6.1%", false, rgb(0xE5484D), "4.07% last week"),
                (1730, "REVENUE", "$128.4k", "4.2%", true, rgb(0x1FA97C), "$123.2k last week"),
            ]
            for card in cards {
                rr(ctx, CGRect(x: card.x, y: 200, width: 613, height: 172), 16, fill: .white, stroke: rgb(0xE6EBF2), lineWidth: 2)
                text(ctx, card.label, size: 20, weight: .medium, color: rgb(0x8494AB), at: CGPoint(x: card.x + 36, y: 238), tracking: 1.5)
                text(ctx, card.value, size: 56, weight: .bold, color: rgb(0x0F1B2D), at: CGPoint(x: card.x + 36, y: 272))
                let valueWidth = textWidth(card.value, size: 56, weight: .bold)
                triangle(ctx, apexTopMid: CGPoint(x: card.x + 36 + valueWidth + 30, y: card.up ? 296 : 310),
                         width: 16, height: 14, up: card.up, color: card.deltaColor)
                text(ctx, card.delta, size: 24, weight: .semibold, color: card.deltaColor, at: CGPoint(x: card.x + 36 + valueWidth + 46, y: 292))
                text(ctx, card.sub, size: 22, color: rgb(0x93A3BE), at: CGPoint(x: card.x + 36, y: 336))
            }

            // Daily active users card.
            rr(ctx, CGRect(x: 456, y: 412, width: 1120, height: 450), 16, fill: .white, stroke: rgb(0xE6EBF2), lineWidth: 2)
            text(ctx, "Daily active users", size: 30, weight: .semibold, color: rgb(0x0F1B2D), at: CGPoint(x: 492, y: 448))
            textRight(ctx, "DAU", size: 22, color: rgb(0x6B7A92), rightX: 1540, y: 456)
            circle(ctx, center: CGPoint(x: 1540 - textWidth("DAU", size: 22) - 18, y: 468), radius: 7, fill: rgb(0x4AA9E8))
            text(ctx, "Unique sessions · all platforms", size: 22, color: rgb(0x93A3BE), at: CGPoint(x: 492, y: 494))

            let points: [CGPoint] = [
                CGPoint(x: 520, y: 640), CGPoint(x: 688, y: 602), CGPoint(x: 856, y: 616),
                CGPoint(x: 1024, y: 644), CGPoint(x: 1192, y: 662), CGPoint(x: 1360, y: 750),
                CGPoint(x: 1528, y: 612),
            ]
            let baseline: CGFloat = 800
            let areaPath = CGMutablePath()
            areaPath.move(to: points[0])
            for point in points.dropFirst() { areaPath.addLine(to: point) }
            areaPath.addLine(to: CGPoint(x: points[points.count - 1].x, y: baseline))
            areaPath.addLine(to: CGPoint(x: points[0].x, y: baseline))
            areaPath.closeSubpath()
            ctx.addPath(areaPath)
            ctx.setFillColor(rgb(0xD9EDFC, 0.85).cgColor)
            ctx.fillPath()

            strokePath(ctx, { p in
                p.move(to: points[0])
                for point in points.dropFirst() { p.addLine(to: point) }
            }, color: rgb(0x45A7EC), width: 5)
            for point in points {
                circle(ctx, center: point, radius: 7, fill: .white, stroke: rgb(0x45A7EC), lineWidth: 4)
            }
            strokePath(ctx, { p in
                p.move(to: CGPoint(x: 1360, y: 750)); p.addLine(to: CGPoint(x: 1360, y: baseline))
            }, color: rgb(0xE5484D), width: 3, dashed: true)
            circle(ctx, center: CGPoint(x: 1360, y: 750), radius: 9, fill: .white, stroke: rgb(0xE5484D), lineWidth: 4)
            let labels = ["Oct 26", "Oct 27", "Oct 28", "Oct 29", "Oct 30", "Oct 31", "Nov 1"]
            for (index, label) in labels.enumerated() {
                textCentered(ctx, label, size: 20, color: rgb(0x93A3BE), centerX: points[index].x, y: 818)
            }

            // Top pages card.
            rr(ctx, CGRect(x: 1600, y: 412, width: 744, height: 450), 16, fill: .white, stroke: rgb(0xE6EBF2), lineWidth: 2)
            text(ctx, "Top pages", size: 30, weight: .semibold, color: rgb(0x0F1B2D), at: CGPoint(x: 1636, y: 448))
            textRight(ctx, "Sessions", size: 22, color: rgb(0x93A3BE), rightX: 2308, y: 456)
            let pages: [(String, CGFloat, String)] = [
                ("Checkout", 644, "6,482"), ("Collection", 508, "5,109"),
                ("Pricing", 383, "3,847"), ("Search", 290, "2,913"),
            ]
            for (index, page) in pages.enumerated() {
                let y: CGFloat = 540 + CGFloat(index) * 85
                text(ctx, page.0, size: 24, color: rgb(0x33415C), at: CGPoint(x: 1636, y: y))
                textRight(ctx, page.2, size: 22, color: rgb(0x6B7A92), rightX: 2308, y: y + 2)
                rr(ctx, CGRect(x: 1636, y: y + 42, width: 644, height: 12), 6, fill: rgb(0xEEF2F7))
                rr(ctx, CGRect(x: 1636, y: y + 42, width: page.1, height: 12), 6, fill: rgb(0x4AA9E8))
            }

            // Recent signups card.
            rr(ctx, CGRect(x: 456, y: 902, width: 1888, height: 430), 16, fill: .white, stroke: rgb(0xE6EBF2), lineWidth: 2)
            text(ctx, "Recent signups", size: 30, weight: .semibold, color: rgb(0x0F1B2D), at: CGPoint(x: 492, y: 938))
            textRight(ctx, "Last 24 hours", size: 22, color: rgb(0x93A3BE), rightX: 2308, y: 946)
            let columns: [(String, CGFloat)] = [
                ("EMAIL", 492), ("PLAN", 1420), ("MRR", 1700), ("COUNTRY", 1930), ("SOURCE", 2160),
            ]
            for (label, x) in columns {
                text(ctx, label, size: 20, weight: .medium, color: rgb(0x8494AB), at: CGPoint(x: x, y: 1014), tracking: 1.5)
            }
            let rows: [(String, String, NSColor, NSColor, String, String, String)] = [
                ("maya.chen@example.com", "Pro", rgb(0xEFE6FD), rgb(0x7C4DC4), "$49", "United States", "Organic search"),
                ("liam.nguyen@example.com", "Team", rgb(0xE3F5EC), rgb(0x1E9E6A), "$199", "Singapore", "Product Hunt"),
                ("sofia.rossi@example.com", "Starter", rgb(0xE7F1FD), rgb(0x2E7CD6), "$19", "Italy", "Referral"),
            ]
            for (index, row) in rows.enumerated() {
                let y: CGFloat = 1085 + CGFloat(index) * 85
                text(ctx, row.0, size: 24, color: rgb(0x33415C), at: CGPoint(x: 492, y: y))
                let pillWidth = textWidth(row.1, size: 22) + 40
                rr(ctx, CGRect(x: 1420, y: y - 10, width: pillWidth, height: 44), 22, fill: row.2)
                textCentered(ctx, row.1, size: 22, weight: .medium, color: row.3, centerX: 1420 + pillWidth / 2, y: y + 2)
                text(ctx, row.4, size: 24, color: rgb(0x33415C), at: CGPoint(x: 1700, y: y))
                text(ctx, row.5, size: 24, color: rgb(0x33415C), at: CGPoint(x: 1930, y: y))
                text(ctx, row.6, size: 24, color: rgb(0x33415C), at: CGPoint(x: 2160, y: y))
                if index < 2 {
                    fillRect(ctx, CGRect(x: 492, y: y + 52, width: 1816, height: 1), rgb(0xF0F3F8))
                }
            }
        }
    }

    // MARK: - Staged desktop scene (3200×2000 px for a 1600×1000 pt screen)

    static func makeDesktopScene(dashboard: CGImage) -> CGImage {
        flippedContext(width: 1600, height: 1000, scale: 2) { ctx in
            // Wallpaper.
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let wallpaper = CGGradient(
                colorsSpace: space,
                colors: [rgb(0x18263F).cgColor, rgb(0x0C1322).cgColor] as CFArray,
                locations: [0, 1]
            )!
            ctx.drawLinearGradient(
                wallpaper, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1600, y: 1000), options: []
            )

            // Pulse window with a drop shadow.
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 8), blur: 30,
                          color: NSColor.black.withAlphaComponent(0.5).cgColor)
            drawImage(ctx, dashboard, in: CGRect(x: 210, y: 130, width: 1200, height: 750))
            ctx.restoreGState()

            // Menu bar.
            fillRect(ctx, CGRect(x: 0, y: 0, width: 1600, height: 24), NSColor.black.withAlphaComponent(0.82))
            drawAppleSilhouette(ctx, center: CGPoint(x: 22, y: 12))
            text(ctx, "Finder", size: 22, weight: .semibold, color: rgb(0xF2F2F2), at: CGPoint(x: 44, y: 3))
            let menus = [("File", 120), ("Edit", 178), ("View", 234), ("Go", 292), ("Window", 336), ("Help", 420)]
            for (label, x) in menus {
                text(ctx, label, size: 22, color: rgb(0xEAEAEA), at: CGPoint(x: CGFloat(x), y: 3))
            }
            // Right cluster: wifi, battery, clock.
            for radius in [6.0, 12.0, 18.0] {
                strokePath(ctx, { p in
                    p.addArc(
                        center: CGPoint(x: 1266, y: 21), radius: radius,
                        startAngle: .pi + 0.55, endAngle: 2 * .pi - 0.55, clockwise: false
                    )
                }, color: rgb(0xEAEAEA), width: 2.5)
            }
            circle(ctx, center: CGPoint(x: 1266, y: 20), radius: 2.5, fill: rgb(0xEAEAEA))
            rr(ctx, CGRect(x: 1306, y: 8, width: 30, height: 13), 4, stroke: rgb(0xEAEAEA), lineWidth: 1.5)
            fillRect(ctx, CGRect(x: 1309, y: 11, width: 19, height: 7), rgb(0xEAEAEA))
            fillRect(ctx, CGRect(x: 1337, y: 11, width: 2.5, height: 7), rgb(0xEAEAEA))
            textRight(ctx, "Mon Nov 2  9:41 AM", size: 22, color: rgb(0xF2F2F2), rightX: 1588, y: 3)

            // Dock.
            rr(ctx, CGRect(x: 400, y: 906, width: 800, height: 80), 26,
               fill: NSColor.white.withAlphaComponent(0.16),
               stroke: NSColor.white.withAlphaComponent(0.28), lineWidth: 1.5)
            let iconColors: [(NSColor, NSColor)] = [
                (rgb(0x5B9BFF), rgb(0x2E6BE6)),
                (rgb(0xF5F7FA), rgb(0xD8DEE8)),
                (rgb(0x34C759), rgb(0x1FA83D)),
                (rgb(0xFFD426), rgb(0xF0B429)),
                (rgb(0x3E8EF7), rgb(0x2B6FD6)),
                (rgb(0xA46BFF), rgb(0x7A3BE0)),
                (rgb(0x3A3A44), rgb(0x23232B)),
            ]
            for (index, colors) in iconColors.enumerated() {
                let x: CGFloat = 424 + CGFloat(index) * 76
                let space2 = CGColorSpace(name: CGColorSpace.sRGB)!
                let iconGradient = CGGradient(
                    colorsSpace: space2, colors: [colors.0.cgColor, colors.1.cgColor] as CFArray, locations: [0, 1]
                )!
                ctx.saveGState()
                let iconRect = CGRect(x: x, y: 918, width: 56, height: 56)
                let iconPath = CGPath(roundedRect: iconRect, cornerWidth: 14, cornerHeight: 14, transform: nil)
                ctx.addPath(iconPath)
                ctx.clip()
                ctx.drawLinearGradient(
                    iconGradient,
                    start: CGPoint(x: iconRect.minX, y: iconRect.minY),
                    end: CGPoint(x: iconRect.maxX, y: iconRect.maxY), options: []
                )
                ctx.restoreGState()
            }
            // Compass ring on icon 2.
            circle(ctx, center: CGPoint(x: 424 + 76 + 28, y: 946), radius: 16, stroke: rgb(0x3E8EF7), lineWidth: 5)
            // Note lines on icon 4.
            for dy in [14.0, 26.0, 38.0] {
                fillRect(ctx, CGRect(x: 424 + 76 * 3 + 12, y: 918 + dy, width: 32, height: 4), rgb(0xFFFFFF, 0.85))
            }
            // Terminal prompt on icon 7.
            text(ctx, ">_", size: 20, weight: .semibold, color: rgb(0xEAEAEA), at: CGPoint(x: 424 + 76 * 6 + 12, y: 934))
            // Separator + trash.
            fillRect(ctx, CGRect(x: 966, y: 918, width: 1, height: 56), NSColor.white.withAlphaComponent(0.3))
            rr(ctx, CGRect(x: 994, y: 934, width: 30, height: 36), 6, stroke: NSColor.white.withAlphaComponent(0.75), lineWidth: 2.5)
            fillRect(ctx, CGRect(x: 990, y: 928, width: 38, height: 5), NSColor.white.withAlphaComponent(0.75))
            fillRect(ctx, CGRect(x: 1002, y: 922, width: 14, height: 4), NSColor.white.withAlphaComponent(0.75))
        }
    }

    // MARK: - Output

    static func write(_ image: CGImage, to url: URL) {
        let rep = NSBitmapImageRep(cgImage: image)
        write(rep, to: url)
    }

    static func write(_ rep: NSBitmapImageRep, to url: URL) {
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("encode failed for \(url.lastPathComponent)")
            return
        }
        do {
            try data.write(to: url)
            print("\(url.lastPathComponent): \(rep.pixelsWide)x\(rep.pixelsHigh) (\(data.count / 1024) KB)")
        } catch {
            print("write \(url.lastPathComponent): \(error)")
        }
    }
}
