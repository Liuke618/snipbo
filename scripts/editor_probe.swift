import AppKit
import Foundation
import SnipboCore

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
                onTool: { _ in }, onUndo: {}, onRedo: {}, onRedact: { _ in },
                onRecognize: {}, onPin: {}, onCopy: {}, onSave: {}, onShowOptions: {}
            )
            probeToolbar.updateReadouts(size: CGSize(width: 2022, height: 5175), zoom: fitZoom)
            let toolbarFloor = probeToolbar.fittingSize.width
            // Zoom digits change constantly while pinching; the toolbar must
            // not resize (and shift its icons) between "10%" and "800%".
            probeToolbar.updateReadouts(size: CGSize(width: 2022, height: 5175), zoom: 0.1)
            let narrowZoomWidth = probeToolbar.fittingSize.width
            probeToolbar.updateReadouts(size: CGSize(width: 2022, height: 5175), zoom: 8)
            let wideZoomWidth = probeToolbar.fittingSize.width
            check("toolbar: width independent of zoom digits",
                  abs(narrowZoomWidth - wideZoomWidth) < 0.5,
                  "\(Int(narrowZoomWidth)) vs \(Int(wideZoomWidth))")
            let expectedWidth = min(max(640, 2022 * fitZoom, toolbarFloor), screen.width * 0.9)
            let expectedHeight = min(max(320, 5175 * fitZoom), screen.height * 0.9) + 36
            check("large: window hugs fitted image (toolbar floor respected)",
                  abs(content.width - expectedWidth) <= 12 && abs(content.height - expectedHeight) < 2,
                  "got \(Int(content.width))x\(Int(content.height)), want \(Int(expectedWidth))x\(Int(expectedHeight)) (toolbar floor \(Int(toolbarFloor)))")
            check("large: window fits the screen",
                  window.frame.width <= screen.width && window.frame.height <= screen.height + 2,
                  "frame \(window.frame), screen \(screen)")
            render(window, to: "/tmp/snipbo-editor-large.png")
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
            render(window, to: "/tmp/snipbo-editor-small.png")
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

        // --- Case 4: crop draft commit/cancel (Enter/Escape semantics).
        let cropEditor = makeEditor(image: makeImage(width: 400, height: 300))
        cropEditor.show()
        runTicks(6)
        let cropController = cropEditor.controller
        cropController.tool = .crop
        cropController.begin(at: CGPoint(x: 50, y: 40))
        cropController.drag(to: CGPoint(x: 250, y: 190))
        check("crop: draft visible", cropController.cropDraft != nil, "nil draft")
        if let window = cropEditor.window { render(window, to: "/tmp/snipbo-editor-crop.png") }
        cropController.cancelCropDraft()
        check("crop: escape cancels draft", cropController.cropDraft == nil, "draft survived")
        check("crop: cancel keeps crop rect",
              cropController.document.cropRect.width == 400 && cropController.document.cropRect.height == 300,
              "\(cropController.document.cropRect)")
        cropController.begin(at: CGPoint(x: 50, y: 40))
        cropController.drag(to: CGPoint(x: 250, y: 190))
        cropController.commitCropDraft()
        check("crop: enter commits crop",
              cropController.document.cropRect == CGRect(x: 50, y: 40, width: 200, height: 150),
              "\(cropController.document.cropRect)")
        check("crop: commit cleared draft", cropController.cropDraft == nil, "draft survived")
        cropController.undo()
        check("crop: undo restores crop",
              cropController.document.cropRect.width == 400,
              "\(cropController.document.cropRect)")

        // --- Case 5: resize resamples the crop and carries annotations.
        // Current document after undo: full 400x300. Commit a rectangle first
        // so the resize has something to scale.
        cropController.tool = .rectangle
        cropController.begin(at: CGPoint(x: 60, y: 50))
        cropController.drag(to: CGPoint(x: 140, y: 130))
        cropController.end(at: CGPoint(x: 140, y: 130))
        check("resize: rectangle committed", cropController.document.annotations.count == 1,
              "count \(cropController.document.annotations.count)")
        let before = cropController.document
        cropController.resizeImage(toWidth: 200)
        check("resize: image resampled to half",
              cropController.document.image.width == 200 && cropController.document.image.height == 150,
              "\(cropController.document.imagePixelSize)")
        check("resize: crop reset to full image",
              cropController.document.cropRect == CGRect(x: 0, y: 0, width: 200, height: 150),
              "\(cropController.document.cropRect)")
        check("resize: annotation carried and scaled",
              cropController.document.annotations.count == 1
                  && abs(cropController.document.annotations[0].style.lineWidth - 1.5) < 0.01
                  && abs(cropController.document.annotations[0].bounds.minX - 30) < 0.01,
              "\(cropController.document.annotations.first.map { "\($0.bounds) w=\($0.style.lineWidth)" } ?? "none") (before \(before.annotations.first.map { "\($0.bounds) w=\($0.style.lineWidth)" } ?? "none"))")
        check("resize: undo history dropped", cropController.history.undoDepth == 0,
              "undoDepth \(cropController.history.undoDepth)")

        // --- Case 6: logical-point size formatting.
        cropController.showsLogicalPoints = false
        check("sizeText: px by default",
              cropController.sizeText(for: CGSize(width: 200, height: 150)) == "200×150 px",
              cropController.sizeText(for: CGSize(width: 200, height: 150)))
        // A Retina capture (scale 2) shows halved pt values when toggled on.
        let retinaEditor = makeEditor(image: makeImage(width: 346, height: 172))
        // Rebuild the document with an explicit scale via the editor's window;
        // simulate by toggling on a scale-2 document.
        retinaEditor.controller.document = EditDocument(
            image: makeImage(width: 346, height: 172),
            backingScale: 2
        )
        retinaEditor.controller.showsLogicalPoints = true
        check("sizeText: logical points on Retina",
              retinaEditor.controller.sizeText(for: CGSize(width: 346, height: 172)) == "173×86 pt",
              retinaEditor.controller.sizeText(for: CGSize(width: 346, height: 172)))
        retinaEditor.controller.showsLogicalPoints = false
        check("sizeText: px when toggled off",
              retinaEditor.controller.sizeText(for: CGSize(width: 346, height: 172)) == "346×172 px",
              retinaEditor.controller.sizeText(for: CGSize(width: 346, height: 172)))

        cropEditor.close()
        retinaEditor.close()

        // --- Case 7: pins are truly always-on-top and join every Space.
        PinBoard.shared.pin(makeImage(width: 120, height: 80))
        runTicks(4)
        let pinWindow = NSApp.windows.first {
            $0.isVisible && $0 is NSPanel && $0.styleMask.contains(.nonactivatingPanel)
        }
        if let pinWindow {
            check("pin: floats above normal windows",
                  pinWindow.level == .floating, "level \(pinWindow.level.rawValue)")
            check("pin: joins all Spaces",
                  pinWindow.collectionBehavior.contains(.canJoinAllSpaces),
                  "\(pinWindow.collectionBehavior.rawValue)")
            pinWindow.close()
            runTicks(2)
        } else {
            check("pin: window exists", false, "no pin panel found")
        }

        // --- Case 8: tapered arrow rendering (thin + thick).
        let arrowEditor = makeEditor(image: makeImage(width: 420, height: 320))
        arrowEditor.show()
        runTicks(6)
        let arrowController = arrowEditor.controller
        arrowController.tool = .arrow
        arrowController.style.lineWidth = 3
        arrowController.begin(at: CGPoint(x: 40, y: 60))
        arrowController.drag(to: CGPoint(x: 200, y: 170))
        arrowController.end(at: CGPoint(x: 200, y: 170))
        arrowController.style.lineWidth = 16
        arrowController.begin(at: CGPoint(x: 250, y: 50))
        arrowController.drag(to: CGPoint(x: 330, y: 230))
        arrowController.end(at: CGPoint(x: 330, y: 230))
        check("style panel: visible for a drawing tool",
              arrowEditor.stylePanelView?.isHidden == false,
              "hidden while arrow tool is active")
        if let window = arrowEditor.window { render(window, to: "/tmp/snipbo-editor-arrows.png") }

        // The panel hides for plain selection and cropping, and returns when an
        // annotation is selected so its style can still be edited.
        arrowController.tool = .select
        arrowController.setSelected(id: nil)
        runTicks(2)
        check("style panel: hidden for select without a selection",
              arrowEditor.stylePanelView?.isHidden == true,
              "visible while select tool has no selection")
        arrowController.setSelected(id: arrowController.document.annotations[0].id)
        runTicks(2)
        check("style panel: visible with a selected annotation",
              arrowEditor.stylePanelView?.isHidden == false,
              "hidden while an annotation is selected")
        arrowController.tool = .crop
        arrowController.setSelected(id: nil)
        runTicks(2)
        check("style panel: hidden for crop",
              arrowEditor.stylePanelView?.isHidden == true,
              "visible while cropping")

        // The size readout in the toolbar is the resize entry point: clicking
        // it must open the options popover (anchored to that readout).
        if let window = arrowEditor.window,
           let sizeButton = findButton(in: window.contentView, title: "420×320 px") {
            let windowsBefore = Set(NSApp.windows.map(ObjectIdentifier.init))
            sizeButton.performClick(nil)
            runTicks(4)
            let popoverWindow = NSApp.windows.first {
                !windowsBefore.contains(ObjectIdentifier($0)) && $0.isVisible
            }
            check("size readout opens the resize popover",
                  popoverWindow != nil,
                  "no new visible window after clicking the size readout")
            popoverWindow?.orderOut(nil)
        } else {
            check("size readout is clickable", false, "size button not found")
        }
        arrowEditor.close()

        // --- Case 9: multi-select, duplication, alignment, and text layout.
        let multiEditor = makeEditor(image: makeImage(width: 500, height: 400))
        let multi = multiEditor.controller
        multi.tool = .rectangle
        multi.begin(at: CGPoint(x: 40, y: 40))
        multi.drag(to: CGPoint(x: 140, y: 120))
        multi.end(at: CGPoint(x: 140, y: 120))
        multi.begin(at: CGPoint(x: 240, y: 220))
        multi.drag(to: CGPoint(x: 340, y: 300))
        multi.end(at: CGPoint(x: 340, y: 300))
        check("multi: two annotations committed",
              multi.document.annotations.count == 2,
              "count \(multi.document.annotations.count)")

        multi.tool = .select
        multi.setSelected(id: multi.document.annotations[0].id)
        multi.begin(at: CGPoint(x: 290, y: 260), extendSelection: true)
        check("multi: shift-click extends selection",
              multi.selectedIDs.count == 2,
              "selected \(multi.selectedIDs.count)")

        let beforeBounds = multi.document.annotations.map(\.bounds)
        multi.drag(to: CGPoint(x: 300, y: 270))
        let afterBounds = multi.document.annotations.map(\.bounds)
        check("multi: drag moves every selected annotation",
              zip(beforeBounds, afterBounds).allSatisfy { abs($1.minX - $0.minX - 10) < 0.01 },
              "before \(beforeBounds) after \(afterBounds)")
        multi.end(at: CGPoint(x: 300, y: 270))

        multi.alignSelected(.left)
        let lefts = multi.document.annotations.map(\.bounds.minX)
        check("multi: align left",
              abs(lefts[0] - lefts[1]) < 0.01,
              "lefts \(lefts)")

        multi.duplicateSelected()
        check("multi: duplicate adds a second copy",
              multi.document.annotations.count == 4 && multi.selectedIDs.count == 2,
              "count \(multi.document.annotations.count), selected \(multi.selectedIDs.count)")

        multi.copySelectedAnnotations()
        multi.pasteAnnotations()
        check("multi: copy and paste annotations",
              multi.document.annotations.count == 6 && multi.selectedIDs.count == 2,
              "count \(multi.document.annotations.count), selected \(multi.selectedIDs.count)")

        multi.deleteSelected()
        check("multi: delete removes the pasted pair",
              multi.document.annotations.count == 4,
              "count \(multi.document.annotations.count)")

        multi.tool = .text
        multi.style.fontSize = 18
        multi.commitText(
            String(repeating: "wrap ", count: 30),
            at: CGPoint(x: 20, y: 20),
            width: 120
        )
        if case .text = multi.document.annotations.last?.geometry {
            let height = multi.document.annotations.last?.bounds.height ?? 0
            check("text: wrapped annotation grows beyond one line",
                  height > 18 * 1.4 * 2,
                  "height \(height)")
        } else {
            check("text: annotation committed", false, "last annotation is not text")
        }
        multiEditor.close()

        // --- Case 10: drag-out payload carries both a file URL and PNG data.
        if let payload = ImageDragSupport.makePayload(
            image: makeImage(width: 80, height: 60),
            suggestedName: "probe.png"
        ) {
            let fileExists = FileManager.default.fileExists(
                atPath: payload.temporaryFile.path
            )
            let pasteboard = payload.item.item as? NSPasteboardItem
            check("drag: temporary PNG written", fileExists, payload.temporaryFile.path)
            check("drag: pasteboard offers a file URL",
                  pasteboard?.types.contains(.fileURL) == true,
                  "types \(pasteboard?.types.map(\.rawValue) ?? [])")
            check("drag: pasteboard offers PNG data",
                  pasteboard?.types.contains(.png) == true,
                  "types \(pasteboard?.types.map(\.rawValue) ?? [])")
            ImageDragSupport.removeTemporaryFile(payload.temporaryFile)
        } else {
            check("drag: payload created", false, "makePayload returned nil")
        }
        print("probe done")
    }

    /// Finds the borderless readout button by its visible title so the probe
    /// can click it like a user would.
    static func findButton(in view: NSView?, title: String) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.attributedTitle.string == title {
            return button
        }
        for subview in view.subviews {
            if let found = findButton(in: subview, title: title) { return found }
        }
        return nil
    }

    @MainActor
    static func makeEditor(image: CGImage) -> EditorWindowController {
        EditorWindowController(
            document: EditDocument(image: image),
            settingsProvider: { AppSettings.default },
            history: HistoryStore(
                baseDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("snipbo-probe-history", isDirectory: true),
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
    /// stripes drawn by makeImage stand out against the light-gray fill. The
    /// 0.65 threshold keeps the violet selected-tool wash in the toolbar
    /// (blue−red ≈ 0.51) out of the box.
    static func blueBounds(_ rep: NSBitmapImageRep) -> (minX: Int, maxX: Int, minY: Int, maxY: Int) {
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let r = rep.colorAt(x: x, y: y) else { continue }
                let red = r.redComponent, blue = r.blueComponent
                if blue - red > 0.65 {
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
        context.setFillColor(CGColor(red: 0.1, green: 0.35, blue: 0.9, alpha: 1))
        // Stripes touch both edges so the blue bounding box equals the canvas.
        for row in stride(from: 0, to: height, by: 80) {
            context.fill(CGRect(x: 0, y: row, width: width, height: 40))
        }
        return context.makeImage()!
    }
}
