import AppKit
import LightShotCore

/// Builds the status item's "Recent" submenu from the screenshot history.
///
/// Entries are read asynchronously from `HistoryStore`; until the first read
/// completes the menu shows a disabled placeholder. The menu is refreshed when
/// it opens and can be refreshed explicitly (the app does so at launch), so the
/// first open is populated without relying on a menu-open callback having
/// already completed. Entries whose PNG file was deleted are skipped, so a
/// missing screenshot is not offered from a freshly built menu.
@MainActor
final class RecentMenuController: NSObject, NSMenuDelegate {
    /// The number of recent screenshots the menu offers.
    static let maximumItemCount = 10

    let menu = NSMenu(title: "Recent")
    private let history: HistoryStore
    private let openEntry: (HistoryEntry) -> Void
    private var entries: [HistoryEntry] = []
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    init(history: HistoryStore, openEntry: @escaping (HistoryEntry) -> Void) {
        self.history = history
        self.openEntry = openEntry
        super.init()
        menu.delegate = self
        rebuild()
    }

    func menuWillOpen(_ menu: NSMenu) {
        Task { await refresh() }
    }

    /// Reloads the newest entries from the store and rebuilds the menu.
    ///
    /// Missing image files are skipped before the 10-item cap is applied, so a
    /// deleted screenshot does not leave a permanently dead slot at the top of
    /// the menu.
    func refresh() async {
        let stored = await history.entries()
        var available: [HistoryEntry] = []
        available.reserveCapacity(min(stored.count, Self.maximumItemCount))
        for entry in stored {
            guard available.count < Self.maximumItemCount else { break }
            let url = await history.imageURL(for: entry)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            available.append(entry)
        }
        entries = available
        rebuild()
    }

    private func rebuild() {
        menu.removeAllItems()
        guard !entries.isEmpty else {
            let item = NSMenuItem(title: "No recent screenshots", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        for entry in entries {
            let parent = NSMenuItem(title: title(for: entry), action: nil, keyEquivalent: "")
            let submenu = NSMenu()

            let open = NSMenuItem(title: "Open in Editor", action: #selector(openAction(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = entry
            submenu.addItem(open)

            let copy = NSMenuItem(title: "Copy Image", action: #selector(copyAction(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = entry
            submenu.addItem(copy)

            parent.submenu = submenu
            menu.addItem(parent)
        }
    }

    @objc private func openAction(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? HistoryEntry else { return }
        openEntry(entry)
    }

    @objc private func copyAction(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? HistoryEntry else { return }
        Task {
            let url = await history.imageURL(for: entry)
            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                NSLog("LightShot: could not read the recent screenshot at %@", url.path)
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(data, forType: .png)
        }
    }

    private func title(for entry: HistoryEntry) -> String {
        "\(formatter.string(from: entry.createdAt)) · \(entry.pixelWidth)×\(entry.pixelHeight)"
    }
}
