import AppKit

/// The subset of `NSPasteboard` needed to write PNG data with rollback.
///
/// A protocol instead of the concrete class so the write-failure path can be
/// exercised with a fake pasteboard in the committed harness; production code
/// always passes `NSPasteboard.general`.
@MainActor
protocol PasteboardWriting: AnyObject {
    var pasteboardItems: [NSPasteboardItem]? { get }
    @discardableResult func clearContents() -> Int
    func setData(_ data: Data?, forType dataType: NSPasteboard.PasteboardType) -> Bool
    @discardableResult func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool
}

extension NSPasteboard: PasteboardWriting {}

/// Writes PNG data to a pasteboard without losing the user's previous
/// clipboard contents when the write fails.
@MainActor
enum PasteboardWriter {
    /// Clears the pasteboard and writes `data`. Returns false and restores the
    /// previous items when the write is rejected.
    @discardableResult
    static func writePNG(_ data: Data, to pasteboard: any PasteboardWriting) -> Bool {
        let previousItems = snapshot(pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: .png) else {
            restore(previousItems, to: pasteboard)
            return false
        }
        return true
    }

    /// Copies the pasteboard's items so they can be restored after a failed
    /// write. Items read from a pasteboard cannot be written back directly, so
    /// each item's data is copied into a fresh item.
    static func snapshot(_ pasteboard: any PasteboardWriting) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            let copy = NSPasteboardItem()
            var copiedAnyType = false
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                    copiedAnyType = true
                }
            }
            return copiedAnyType ? copy : nil
        }
    }

    static func restore(
        _ items: [NSPasteboardItem],
        to pasteboard: any PasteboardWriting
    ) {
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }
}
