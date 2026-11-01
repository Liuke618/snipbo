import AppKit
import SnipboCore

/// Pre-renders and PNG-encodes the drag-out image while the press is still
/// down, so the mouse-drag handler does not render a 6K document and encode
/// it synchronously on the main thread. `EditorCanvasView` starts the work on
/// mouse-down over empty canvas and consumes it when the drag actually begins;
/// a not-yet-ready payload falls back to the synchronous path.
enum DragOutPreparation {
    struct Prepared {
        /// The document state the payload was rendered from; a mismatch at
        /// use time means the document moved on and the payload is stale.
        let state: DocumentState
        let image: ImageData
        let png: Data
    }

    /// Renders at full export resolution and encodes PNG off the main thread.
    /// Both steps are pure functions of the value snapshot, so they are safe
    /// to run detached.
    static func prepare(_ document: EditDocument) async -> Prepared? {
        await Task.detached(priority: .userInitiated) {
            guard let image = DocumentRenderer.render(document) else { return nil }
            guard let png = ImageExporter.pngData(from: image) else { return nil }
            return Prepared(state: document.state, image: ImageData(image), png: png)
        }.value
    }
}

extension ImageDragSupport {
    /// Payload from an already-rendered and encoded image, skipping the
    /// synchronous render + PNG encode that `makePayload(image:suggestedName:)`
    /// performs. Mirrors that function's file and pasteboard assembly because
    /// its helpers are private to the Platform module.
    static func makePayload(
        prepared: DragOutPreparation.Prepared,
        suggestedName: String
    ) -> Payload? {
        makePayload(png: prepared.png, image: prepared.image.cgImage, suggestedName: suggestedName)
    }

    static func makePayload(
        png: Data,
        image: CGImage,
        suggestedName: String
    ) -> Payload? {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("SnipboDrag", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let base = suggestedName.isEmpty ? "Snipbo.png" : suggestedName
        let invalid = CharacterSet(charactersIn: "/:\\")
        let cleaned = base.components(separatedBy: invalid).joined(separator: "-")
        let name = cleaned.hasSuffix(".png") ? cleaned : cleaned + ".png"
        let url = directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        do {
            try png.write(to: url, options: .atomic)
        } catch {
            return nil
        }

        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setData(png, forType: .png)
        let dragging = NSDraggingItem(pasteboardWriter: item)

        let full = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        let maxSide: CGFloat = 180
        let scale = min(1, maxSide / max(full.size.width, full.size.height))
        let preview = NSImage(size: NSSize(
            width: max(1, full.size.width * scale),
            height: max(1, full.size.height * scale)
        ))
        preview.lockFocus()
        full.draw(in: NSRect(origin: .zero, size: preview.size))
        preview.unlockFocus()
        return Payload(item: dragging, preview: preview, temporaryFile: url)
    }
}
