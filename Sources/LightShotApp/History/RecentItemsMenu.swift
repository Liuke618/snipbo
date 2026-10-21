import AppKit
import LightShotCore

/// Builds the status item's "Recent" submenu from the screenshot history.
///
/// The controller keeps a main-actor cache of the newest entries. The cache is
/// loaded once at init and kept current by the `.lightShotHistoryDidChange`
/// notification that `HistoryRecorder` posts after each successful write, so
/// opening the menu right after a copy/save already includes the new entry.
///
/// `menuWillOpen` rebuilds the menu from the cache synchronously. An async
/// cache refresh that finishes while the menu is open only marks the menu as
/// needing a rebuild; the rebuild runs in `menuDidClose`, so AppKit never has
/// its open menu mutated underneath it. Entries whose PNG file was deleted are
/// skipped, so a missing screenshot is not offered from a freshly built menu.
@MainActor
final class RecentMenuController: NSObject, NSMenuDelegate {
    /// The number of recent screenshots the menu offers.
    static let maximumItemCount = 10

    let menu = NSMenu(title: "Recent")
    private let history: HistoryStore
    private let openEntry: (HistoryEntry) -> Void
    private var entries: [HistoryEntry] = []
    private var isMenuOpen = false
    private var needsRebuild = false
    /// Invalidates an older in-flight refresh when a newer write or refresh
    /// updates the cache first.
    private var refreshGeneration = 0
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(historyDidChange(_:)),
            name: .lightShotHistoryDidChange,
            object: nil
        )
        // Load entries that were already stored before this controller existed.
        Task { await refresh() }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        // Rebuild from the cache only. The cache is kept current by the
        // history notification, so no actor read is needed before showing.
        rebuild()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        guard needsRebuild else { return }
        needsRebuild = false
        rebuild()
    }

    /// Handles a completed history write. `HistoryStore.record` has already
    /// written the PNG when the notification is posted, so the entry can be
    /// inserted synchronously and the menu is never stale on first open.
    @objc private func historyDidChange(_ notification: Notification) {
        // Any refresh that started before this write carries an older list.
        refreshGeneration += 1
        if let entry = notification.object as? HistoryEntry {
            entries.removeAll { $0.id == entry.id }
            entries.insert(entry, at: 0)
            if entries.count > Self.maximumItemCount {
                entries.removeLast(entries.count - Self.maximumItemCount)
            }
            applyCache()
        }
        // Reconcile with pruning (a write can evict older entries) and with
        // files deleted outside the app.
        Task { await refresh() }
    }

    /// Reloads the newest entries from the store into the cache.
    ///
    /// Missing image files are skipped before the 10-item cap is applied, so a
    /// deleted screenshot does not leave a permanently dead slot at the top of
    /// the menu.
    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let stored = await history.entries()
        var available: [HistoryEntry] = []
        available.reserveCapacity(min(stored.count, Self.maximumItemCount))
        for entry in stored {
            guard available.count < Self.maximumItemCount else { break }
            let url = await history.imageURL(for: entry)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            available.append(entry)
        }
        guard generation == refreshGeneration else { return }
        entries = available
        applyCache()
    }

    /// Applies the cached entries to the menu when it is safe to do so. An
    /// open menu is left untouched; the pending rebuild happens on close.
    private func applyCache() {
        guard !isMenuOpen else {
            needsRebuild = true
            return
        }
        needsRebuild = false
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
