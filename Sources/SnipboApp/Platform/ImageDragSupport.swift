import AppKit
import SnipboCore

/// Builds pasteboard payloads for dragging an image out of Snipbo. The item
/// carries both a temporary PNG file URL (Finder, WeChat, Mail) and raw PNG
/// data (apps that accept image data but not files).
@MainActor
enum ImageDragSupport {
    struct Payload {
        let item: NSDraggingItem
        let preview: NSImage
        /// Removed when the drag session ends.
        let temporaryFile: URL
    }

    private static var directory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipboDrag", isDirectory: true)
    }

    /// Writes the rendered image to a unique temporary PNG and wraps it in a
    /// dragging item. Returns nil when encoding or writing fails.
    static func makePayload(
        image: CGImage,
        suggestedName: String
    ) -> Payload? {
        guard let png = ImageExporter.pngData(from: image) else { return nil }
        let fileManager = FileManager.default
        let directory = Self.directory
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let base = sanitized(suggestedName)
        let url = directory.appendingPathComponent("\(UUID().uuidString)-\(base)")
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

    static func removeTemporaryFile(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Sweeps files left behind by a crash or a drag session interrupted by
    /// app termination.
    static func cleanup() {
        let fileManager = FileManager.default
        let directory = Self.directory
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for file in files {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let date, date < cutoff {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    private static func sanitized(_ name: String) -> String {
        let base = name.isEmpty ? "Snipbo.png" : name
        let invalid = CharacterSet(charactersIn: "/:\\")
        let cleaned = base.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.hasSuffix(".png") ? cleaned : cleaned + ".png"
    }
}
