import AppKit
import ImageIO
import SnipboCore
import SwiftUI

/// Owns the single history browser window.
@MainActor
final class HistoryBrowserWindowController: NSWindowController {
    init(store: HistoryStore, openInEditor: @escaping (HistoryEntry) -> Void) {
        let model = HistoryBrowserModel(store: store)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.tr("Screenshot History", "截图历史")
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: HistoryBrowserView(model: model, openInEditor: openInEditor)
        )
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Loads history entries and thumbnails for the grid. ObservableObject
/// instead of SwiftUI @State macros, which this toolchain cannot expand.
@MainActor
final class HistoryBrowserModel: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]

    private let store: HistoryStore
    private var reloadGeneration = 0
    /// Only written during init and read in deinit, where exclusive access is
    /// guaranteed; the notification block itself captures `self` weakly.
    nonisolated(unsafe) private var historyObserver: NSObjectProtocol?

    init(store: HistoryStore) {
        self.store = store
        historyObserver = NotificationCenter.default.addObserver(
            forName: .snipboHistoryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.reload()
            }
        }
    }

    deinit {
        if let historyObserver {
            NotificationCenter.default.removeObserver(historyObserver)
        }
    }

    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let list = await store.entries()
        guard generation == reloadGeneration else { return }
        entries = list
        // Drop thumbnails of removed entries.
        let liveIDs = Set(list.map(\.id))
        thumbnails = thumbnails.filter { liveIDs.contains($0.key) }

        let missing = list.filter { thumbnails[$0.id] == nil }
        guard !missing.isEmpty else { return }
        let directory = store.directory

        // Decode a few thumbnails at a time off the main actor, publishing each
        // as it finishes instead of blocking the grid on the whole list.
        var iterator = missing.makeIterator()
        await withTaskGroup(of: (UUID, ImageData?).self) { group in
            for _ in 0..<4 {
                guard let entry = iterator.next() else { break }
                let url = directory.appendingPathComponent(entry.thumbnailFileName)
                group.addTask {
                    (entry.id, Self.loadThumbnail(at: url))
                }
            }
            while let (id, payload) = await group.next() {
                guard generation == reloadGeneration else {
                    group.cancelAll()
                    return
                }
                if let payload, liveIDs.contains(id) {
                    thumbnails[id] = NSImage(
                        cgImage: payload.cgImage,
                        size: NSSize(
                            width: payload.cgImage.width,
                            height: payload.cgImage.height
                        )
                    )
                }
                if let entry = iterator.next() {
                    let url = directory.appendingPathComponent(entry.thumbnailFileName)
                    group.addTask {
                        (entry.id, Self.loadThumbnail(at: url))
                    }
                }
            }
        }
    }

    func delete(_ entry: HistoryEntry) async {
        do {
            try await store.remove(id: entry.id)
        } catch {
            NSLog("Snipbo: history delete failed: \(error.localizedDescription)")
            return
        }
        thumbnails.removeValue(forKey: entry.id)
        await reload()
    }

    func clearAll() async {
        do {
            try await store.clear()
        } catch {
            NSLog("Snipbo: history clear failed: \(error.localizedDescription)")
            return
        }
        thumbnails.removeAll()
        await reload()
    }

    func pin(_ entry: HistoryEntry) async {
        let url = await store.imageURL(for: entry)
        let payload = await Task.detached(priority: .userInitiated) {
            Self.loadFullImage(at: url)
        }.value
        guard let payload else { return }
        PinBoard.shared.pin(payload.cgImage)
    }

    func copy(_ entry: HistoryEntry) async {
        let url = await store.imageURL(for: entry)
        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: url)
        }.value
        guard let data, !data.isEmpty else { return }
        // The stored file is already a PNG; do not decode and re-encode it on
        // the main thread just to copy it.
        _ = PasteboardWriter.writePNG(data, to: NSPasteboard.general)
    }

    func reveal(_ entry: HistoryEntry) async {
        let url = await store.imageURL(for: entry)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private nonisolated static func loadThumbnail(at url: URL) -> ImageData? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else { return nil }
        return ImageData(image)
    }

    private nonisolated static func loadFullImage(at url: URL) -> ImageData? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return ImageData(image)
    }
}

/// Grid browser over the history store: double-click reopens the editor, the
/// context menu pins, copies, reveals, or deletes an entry.
struct HistoryBrowserView: View {
    @ObservedObject var model: HistoryBrowserModel
    let openInEditor: (HistoryEntry) -> Void

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.tr(
                    "\(model.entries.count) screenshots · originals",
                    "\(model.entries.count) 张截图 · 原始图"
                ))
                .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("Clear All", "全部清空")) {
                    confirmClearAll()
                }
                .disabled(model.entries.isEmpty)
            }
            .padding(12)
            Divider()
            if model.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text(L10n.tr("No screenshots yet. They appear here after you copy or save one.", "还没有截图。复制或保存后，截图会出现在这里。"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 230), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(model.entries) { entry in
                            thumbnailCell(entry)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 660, minHeight: 480)
        .onAppear {
            Task { await model.reload() }
        }
    }

    private func confirmClearAll() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("Clear all screenshots?", "清空全部截图？")
        alert.informativeText = L10n.tr(
            "This permanently deletes every screenshot in the history. It cannot be undone.",
            "这会永久删除历史中的所有截图，且无法撤销。"
        )
        alert.addButton(withTitle: L10n.tr("Clear All", "全部清空"))
        alert.addButton(withTitle: L10n.tr("Cancel", "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await model.clearAll() }
    }

    @ViewBuilder
    private func thumbnailCell(_ entry: HistoryEntry) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
                if let image = model.thumbnails[entry.id] {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 150)
                } else {
                    Text("…")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 160)
            Text("\(entry.pixelWidth) × \(entry.pixelHeight) · \(dateFormatter.string(from: entry.createdAt))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(count: 2) { openInEditor(entry) }
        .contextMenu {
            Button(L10n.tr("Open in Editor", "在编辑器中打开")) { openInEditor(entry) }
            Button(L10n.tr("Pin", "贴图")) { Task { await model.pin(entry) } }
            Button(L10n.tr("Copy", "复制")) { Task { await model.copy(entry) } }
            Button(L10n.tr("Show in Finder", "在 Finder 中显示")) { Task { await model.reveal(entry) } }
            Divider()
            Button(L10n.tr("Delete", "删除"), role: .destructive) {
                Task { await model.delete(entry) }
            }
        }
    }
}
