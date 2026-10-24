import AppKit
import LightShotCore
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
        window.title = "Screenshot History"
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
    @Published private(set) var loadFailed = false

    private let store: HistoryStore

    init(store: HistoryStore) {
        self.store = store
    }

    func reload() async {
        let list = await store.entries()
        entries = list
        loadFailed = false
        // Drop thumbnails of removed entries.
        let liveIDs = Set(list.map(\.id))
        thumbnails = thumbnails.filter { liveIDs.contains($0.key) }
        for entry in list where thumbnails[entry.id] == nil {
            let url = await store.thumbnailURL(for: entry)
            if let image = NSImage(contentsOf: url) {
                thumbnails[entry.id] = image
            }
        }
    }

    func markUnavailable() {
        loadFailed = true
    }

    func delete(_ entry: HistoryEntry) async {
        try? await store.remove(id: entry.id)
        thumbnails.removeValue(forKey: entry.id)
        await reload()
    }

    func clearAll() async {
        try? await store.clear()
        thumbnails.removeAll()
        await reload()
    }

    func pin(_ entry: HistoryEntry) async {
        guard let image = await loadImage(entry) else { return }
        PinBoard.shared.pin(image)
    }

    func copy(_ entry: HistoryEntry) async {
        guard let image = await loadImage(entry),
              let data = ImageExporter.pngData(from: image) else { return }
        _ = PasteboardWriter.writePNG(data, to: NSPasteboard.general)
    }

    func reveal(_ entry: HistoryEntry) async {
        let url = await store.imageURL(for: entry)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func loadImage(_ entry: HistoryEntry) async -> CGImage? {
        let url = await store.imageURL(for: entry)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
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
                Text("\(model.entries.count) screenshots")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear All") {
                    Task { await model.clearAll() }
                }
                .disabled(model.entries.isEmpty)
            }
            .padding(12)
            Divider()
            if model.loadFailed {
                Text("The history index could not be read.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No screenshots yet. They appear here after you copy or save one.")
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
            Button("Open in Editor") { openInEditor(entry) }
            Button("Pin") { Task { await model.pin(entry) } }
            Button("Copy") { Task { await model.copy(entry) } }
            Button("Show in Finder") { Task { await model.reveal(entry) } }
            Divider()
            Button("Delete", role: .destructive) {
                Task { await model.delete(entry) }
            }
        }
    }
}
