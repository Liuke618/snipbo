import AppKit
import Foundation
import LightShotCore

// Editor layout probe (compiles together with the app sources):
// 1. A large capture opens in a window sized to the image, capped to 90% of
//    the screen.
// 2. A crop smaller than the viewport is centered in the scroll view (blue
//    bounding-box center of the rendered window).
// 3. The width slider path live-edits the selected annotation with one undo
//    entry per edit run; the default style is edited when nothing is selected.


@MainActor var failures = 0

@MainActor
func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    let mark = condition ? "PASS" : "FAIL"
    if !condition { failures += 1 }
    print("\(mark)  \(label)\(condition ? "" : " (\(detail))")")
}

@main
struct EditorProbe {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            run()
            print(failures == 0 ? "probe: all checks passed" : "probe: \(failures) check(s) failed")
            exit(failures == 0 ? 0 : 1)
        }
        while true {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    @MainActor
    static func run() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        print("screen visible frame: \(screen)")

        // --- Case 1: large 2022x5175 capture.
        var editor = makeEditor(image: makeImage(width: 2022, height: 5175))
        editor.show()
        runTicks(10)
        if let window = editor.window {
            let content = window.contentView!.frame.size
            // The window hugs the image's displayed size: fit into 90% of the
            // screen first, floored at 640 pt — but never narrower than the
            // toolbar's intrinsic width, which the probe binary inflates
            // (labels instead of bundled icons).
            let fitZoom = min(screen.width * 0.9 / 2022, screen.height * 0.9 / 5175, 1)
            // Measure the toolbar floor with the real readout strings — the
            // size label ("2022×5175 px") is much wider than the placeholder.
            let probeToolbar = EditorToolbarView(
                onTool: { _ in }, onUndo: {}, onRedo: {}, onColor: { _ in }, onWidth: { _ in },
                onRecognize: {}, onPin: {}, onCopy: {}, onSave: {}
            )
            probeToolbar.updateReadouts(size: CGSize(width: 2022, height: 5175), zoom: fitZoom)
            let toolbarFloor = probeToolbar.fittingSize.width
            let expectedWidth = min(max(640, 2022 * fitZoom, toolbarFloor), screen.width * 0.9)
            let expectedHeight = min(max(320, 5175 * fitZoom), screen.height * 0.9) + 36
            check("large: window hugs fitted image (toolbar floor respected)",
                  abs(content.width - expectedWidth) <= 8 && abs(content.height - expectedHeight) < 2,
                  "got \(Int(content.width))x\(Int(content.height)), want \(Int(expectedWidth))x\(Int(expectedHeight)) (toolbar floor \(Int(toolbarFloor)))")
            check("large: window fits the screen",
                  window.frame.width <= screen.width && window.frame.height <= screen.height + 2,
                  "frame \(window.frame), screen \(screen)")
            render(window, to: "/tmp/lightshot-editor-large.png")
            dumpClipGeometry(window)
            if let bitmap = bitmap(window) {
                // The canvas (334 pt wide at fit zoom) must be centered in the
                // 1361 pt viewport, not hugging the left edge.
                let box = blueBounds(bitmap)
                let centerX = Double((box.minX + box.maxX) / 2)
                let wantX = Double(bitmap.pixelsWide / 2)
                check("large: crop centered horizontally", abs(centerX - wantX) <= 10,
                      "center \(centerX), want \(wantX)")
            }
        } else {
            check("large: window exists", false, "no window")
        }
        editor.close()

        // --- Case 2: small 300x200 capture. The window cannot shrink below
        // the toolbar's intrinsic width, so only centering and the 1:1 zoom
        // are asserted, relative to the actual content size.
        editor = makeEditor(image: makeImage(width: 300, height: 200))
        editor.show()
        runTicks(10)
        if let window = editor.window {
            render(window, to: "/tmp/lightshot-editor-small.png")
            dumpClipGeometry(window)
            if let bitmap = bitmap(window) {
                let content = window.contentView!.frame.size
                let scale = Double(bitmap.pixelsWide) / content.width
                let box = blueBounds(bitmap)
                // cacheDisplay bitmaps are top-down: row 0 is the content's
                // top edge. Centered canvas → blue center at the content's
                // midpoint x and the midpoint of the scroll area (which spans
                // from 36 pt down to the content bottom) y.
                let centerX = Double((box.minX + box.maxX) / 2)
                let centerY = Double((box.minY + box.maxY) / 2)
                let wantX = Double(bitmap.pixelsWide / 2)
                let wantY = (36 + (content.height - 36) / 2) * scale
                check("small: crop centered horizontally", abs(centerX - wantX) <= 8,
                      "center \(centerX), want \(wantX)")
                check("small: crop centered vertically", abs(centerY - wantY) <= 8,
                      "center \(centerY), want \(Int(wantY))")
                check("small: opens at 100% zoom", abs(Double(box.maxX - box.minX) / scale - 299) <= 6,
                      "blue width \(box.maxX - box.minX) px, scale \(scale)")
            } else {
                check("small: rendered bitmap", false, "no bitmap")
            }

            // --- Pinch-anchored zoom: the image point under the anchor stays
            // at the same viewport position across the zoom.
            let canvas = editor.canvasView
            if let clip = canvas.superview as? NSClipView {
                let cropOrigin = editor.controller.document.cropRect.origin
                let anchor = CGPoint(x: 150, y: 100)
                let oldOrigin = clip.bounds.origin
                let offset = CGPoint(x: anchor.x - oldOrigin.x, y: anchor.y - oldOrigin.y)
                let imageBefore = CGPoint(
                    x: anchor.x / canvas.zoom + cropOrigin.x,
                    y: anchor.y / canvas.zoom + cropOrigin.y
                )
                canvas.setZoom(2.5, anchoredAt: anchor)
                check("pinch: zoom applied", abs(canvas.zoom - 2.5) < 0.001, "zoom \(canvas.zoom)")
                let anchorInDoc = CGPoint(
                    x: clip.bounds.origin.x + offset.x,
                    y: clip.bounds.origin.y + offset.y
                )
                let imageAfter = CGPoint(
                    x: anchorInDoc.x / canvas.zoom + cropOrigin.x,
                    y: anchorInDoc.y / canvas.zoom + cropOrigin.y
                )
                check("pinch: anchor image point preserved",
                      abs(imageAfter.x - imageBefore.x) < 0.6 && abs(imageAfter.y - imageBefore.y) < 0.6,
                      "\(imageBefore) → \(imageAfter)")
                canvas.setZoom(-5, anchoredAt: anchor)
                check("pinch: zoom floor respected", abs(canvas.zoom - 0.1) < 0.001, "zoom \(canvas.zoom)")
                canvas.setZoom(100, anchoredAt: anchor)
                check("pinch: zoom cap respected", abs(canvas.zoom - 8) < 0.001, "zoom \(canvas.zoom)")
            } else {
                check("pinch: canvas in clip view", false, "no clip superview")
            }
        }
        editor.close()

        // --- Case 3: style edits through the controller.
        let controller = editor.controller
        controller.tool = .rectangle
        controller.begin(at: CGPoint(x: 50, y: 50))
        controller.drag(to: CGPoint(x: 150, y: 130))
        controller.end(at: CGPoint(x: 150, y: 130))
        check("rectangle committed", controller.document.annotations.count == 1,
              "count \(controller.document.annotations.count)")
        let annotationID = controller.document.annotations[0].id

        controller.setSelected(id: annotationID)
        check("selection exposes style", controller.selectedStyle != nil, "nil")
        controller.setLineWidth(10)
        controller.setLineWidth(14)
        controller.setLineWidth(18)
        check("style run edits selected annotation",
              abs(controller.document.annotations[0].style.lineWidth - 18) < 0.001,
              "lineWidth \(controller.document.annotations[0].style.lineWidth)")
        check("style run records one undo entry", controller.history.undoDepth == 2,
              "undoDepth \(controller.history.undoDepth) (commit + style run)")

        controller.undo()
        check("undo reverts style run",
              abs(controller.document.annotations[0].style.lineWidth - 3) < 0.001,
              "lineWidth \(controller.document.annotations[0].style.lineWidth)")
        controller.redo()
        check("redo reapplies style run",
              abs(controller.document.annotations[0].style.lineWidth - 18) < 0.001,
              "lineWidth \(controller.document.annotations[0].style.lineWidth)")

        controller.setSelected(id: nil)
        controller.setLineWidth(7)
        check("no selection: default style updated",
              abs(controller.style.lineWidth - 7) < 0.001,
              "style.lineWidth \(controller.style.lineWidth)")
        check("no selection: annotation untouched",
              abs(controller.document.annotations[0].style.lineWidth - 18) < 0.001,
              "annotation lineWidth \(controller.document.annotations[0].style.lineWidth)")

        // A structural edit after a style run starts a fresh undo entry.
        controller.setSelected(id: annotationID)
        controller.setLineWidth(9)
        controller.deleteSelected()
        controller.undo()
        check("structural edit after style run undoes to the styled state",
              controller.document.annotations.count == 1
                  && abs(controller.document.annotations[0].style.lineWidth - 9) < 0.001,
              "count \(controller.document.annotations.count), lineWidth \(controller.document.annotations.first?.style.lineWidth ?? -1)")
    }

    @MainActor
    static func makeEditor(image: CGImage) -> EditorWindowController {
        EditorWindowController(
            document: EditDocument(image: image),
            settingsProvider: { AppSettings.default },
            history: HistoryStore(
                baseDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("lightshot-probe-history", isDirectory: true),
                maxItems: 20,
                maxBytes: 64 * 1024 * 1024
            ),
            onClose: {}
        )
    }

    @MainActor
    static func runTicks(_ count: Int) {
        for _ in 0..<count { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    @MainActor
    static func dumpClipGeometry(_ window: NSWindow) {
        guard let content = window.contentView else { return }
        var stack: [NSView] = [content]
        while let view = stack.popLast() {
            stack.append(contentsOf: view.subviews)
            if let clip = view as? NSClipView {
                let doc = clip.documentView
                print("clip: bounds=\(clip.bounds) docRect=\(clip.documentRect) docFrame=\(doc?.frame ?? .zero) flipped=\(clip.isFlipped) docFlipped=\(doc?.isFlipped ?? false)")
            }
            if let scroll = view as? NSScrollView {
                print("scroll: contentSize=\(scroll.contentSize) documentVisibleRect=\(scroll.documentVisibleRect)")
            }
        }
    }

    @MainActor
    static func render(_ window: NSWindow, to path: String) {
        guard let bitmap = bitmap(window) else {
            print("render \(path): no bitmap")
            return
        }
        let url = URL(fileURLWithPath: path)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        print("rendered \(Int(window.frame.width))x\(Int(window.frame.height)) → \(path)")
    }

    @MainActor
    static func bitmap(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let content = window.contentView else { return nil }
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
        content.cacheDisplay(in: content.bounds, to: rep)
        return rep
    }

    /// Bounding box (bottom-up bitmap coordinates) of "blue" pixels: the
    /// stripes drawn by makeImage stand out against the light-gray fill.
    static func blueBounds(_ rep: NSBitmapImageRep) -> (minX: Int, maxX: Int, minY: Int, maxY: Int) {
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let r = rep.colorAt(x: x, y: y) else { continue }
                let red = r.redComponent, blue = r.blueComponent
                if blue - red > 0.25 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        return (minX, maxX, minY, maxY)
    }

    static func makeImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        // Stripes touch both edges so the blue bounding box equals the canvas.
        for row in stride(from: 0, to: height, by: 80) {
            context.fill(CGRect(x: 0, y: row, width: width, height: 40))
        }
        return context.makeImage()!
    }
}
