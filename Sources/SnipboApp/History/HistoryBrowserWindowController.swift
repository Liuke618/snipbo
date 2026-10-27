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

enum HistorySourceFilter: String, CaseIterable {
    case all, region, window, screen, scrolling

    var title: String {
        switch self {
        case .all: return L10n.tr("All sources", "全部来源")
        case .region: return L10n.tr("Region", "区域")
        case .window: return L10n.tr("Window", "窗口")
        case .screen: return L10n.tr("Screen", "屏幕")
        case .scrolling: return L10n.tr("Scrolling", "滚动")
        }
    }

    func matches(_ source: CaptureSource) -> Bool {
        switch self {
        case .all: return true
        case .region: return source == .region
        case .window: return source == .window
        case .screen: return source == .fullScreen
        case .scrolling: return source == .scrolling
        }
    }
}

enum HistoryDateFilter: String, CaseIterable {
    case all, today, week, month

    var title: String {
        switch self {
        case .all: return L10n.tr("All time", "全部时间")
        case .today: return L10n.tr("Today", "今天")
        case .week: return L10n.tr("7 days", "7 天")
        case .month: return L10n.tr("30 days", "30 天")
        }
    }

    func matches(_ date: Date, now: Date = Date()) -> Bool {
        switch self {
        case .all:
            return true
        case .today:
            return Calendar.current.isDateInToday(date)
        case .week:
            return date >= now.addingTimeInterval(-7 * 24 * 60 * 60)
        case .month:
            return date >= now.addingTimeInterval(-30 * 24 * 60 * 60)
        }
    }
}

/// Loads history entries and thumbnails for the grid. ObservableObject
/// instead of SwiftUI @State macros, which this toolchain cannot expand.
@MainActor
final class HistoryBrowserModel: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]
    @Published var query = ""
    @Published var sourceFilter: HistorySourceFilter = .all
    @Published var dateFilter: HistoryDateFilter = .all
    @Published var favoritesOnly = false

    var filteredEntries: [HistoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.filter { entry in
            guard sourceFilter.matches(entry.source),
                  dateFilter.matches(entry.createdAt) else { return false }
            if favoritesOnly && !entry.isFavorite { return false }
            guard !needle.isEmpty else { return true }
            if entry.ocrText?.lowercased().contains(needle) == true { return true }
            return entry.tags.contains { $0.lowercased().contains(needle) }
        }
    }

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

    func toggleFavorite(_ entry: HistoryEntry) async {
        do {
            try await store.setFavorite(id: entry.id, isFavorite: !entry.isFavorite)
            await reload()
        } catch {
            NSLog("Snipbo: favorite update failed: \(error.localizedDescription)")
        }
    }

    func addTags(_ raw: String, to entry: HistoryEntry) async {
        let additions = raw
            .split(separator: ",", omittingEmptySubsequences: true)
            .map(String.init)
        guard !additions.isEmpty else { return }
        do {
            try await store.setTags(id: entry.id, tags: entry.tags + additions)
            await reload()
        } catch {
            NSLog("Snipbo: tag update failed: \(error.localizedDescription)")
        }
    }

    func removeTag(_ tag: String, from entry: HistoryEntry) async {
        do {
            try await store.setTags(
                id: entry.id,
                tags: entry.tags.filter { $0 != tag }
            )
            await reload()
        } catch {
            NSLog("Snipbo: tag update failed: \(error.localizedDescription)")
        }
    }

    func clearTags(_ entry: HistoryEntry) async {
        do {
            try await store.setTags(id: entry.id, tags: [])
            await reload()
        } catch {
            NSLog("Snipbo: tag update failed: \(error.localizedDescription)")
        }
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

    /// Drags the stored PNG as a file. Falling back to the cached thumbnail
    /// keeps the gesture usable while the file is being cleaned up.
    func dragProvider(for entry: HistoryEntry) -> NSItemProvider {
        let url = store.directory.appendingPathComponent(entry.imageFileName)
        if FileManager.default.fileExists(atPath: url.path),
           let provider = NSItemProvider(contentsOf: url) {
            return provider
        }
        if let image = thumbnails[entry.id] {
            return NSItemProvider(object: image)
        }
        return NSItemProvider()
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
            HStack(spacing: 8) {
                HistorySearchField(
                    text: $model.query,
                    placeholder: L10n.tr("Search text or tags", "搜索文字或标签")
                )
                .frame(minWidth: 150, maxWidth: .infinity)

                Picker("", selection: $model.sourceFilter) {
                    ForEach(HistorySourceFilter.allCases, id: \.self) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .labelsHidden()
                .frame(width: 108)

                Picker("", selection: $model.dateFilter) {
                    ForEach(HistoryDateFilter.allCases, id: \.self) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .labelsHidden()
                .frame(width: 98)

                Toggle(L10n.tr("Favorites", "收藏"), isOn: $model.favoritesOnly)
                    .toggleStyle(.button)
                    .controlSize(.small)

                Text("\(model.filteredEntries.count)/\(model.entries.count)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

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
            } else if model.filteredEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text(L10n.tr("No screenshots match the search.", "没有匹配的截图。"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 230), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(model.filteredEntries) { entry in
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
            if !entry.tags.isEmpty {
                Text(entry.tags.map { "#\($0)" }.joined(separator: " "))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
        .overlay(alignment: .topTrailing) {
            if entry.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.yellow)
                    .padding(7)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onDrag { model.dragProvider(for: entry) }
        .onTapGesture(count: 2) { openInEditor(entry) }
        .contextMenu {
            Button(entry.isFavorite
                ? L10n.tr("Unfavorite", "取消收藏")
                : L10n.tr("Favorite", "收藏")) {
                Task { await model.toggleFavorite(entry) }
            }
            Button(L10n.tr("Add Tag…", "添加标签…")) {
                promptForTag(entry)
            }
            if !entry.tags.isEmpty {
                Menu(L10n.tr("Remove Tag", "移除标签")) {
                    ForEach(entry.tags, id: \.self) { tag in
                        Button("#\(tag)") {
                            Task { await model.removeTag(tag, from: entry) }
                        }
                    }
                }
                Button(L10n.tr("Clear Tags", "清空标签")) {
                    Task { await model.clearTags(entry) }
                }
            }
            Divider()
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

    private func promptForTag(_ entry: HistoryEntry) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("Add Tag", "添加标签")
        alert.informativeText = L10n.tr(
            "Separate multiple tags with commas.",
            "多个标签用逗号分隔。"
        )
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = L10n.tr("tag", "标签")
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.tr("Add", "添加"))
        alert.addButton(withTitle: L10n.tr("Cancel", "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        Task { await model.addTags(value, to: entry) }
    }
}

/// SwiftUI's TextField on this toolchain only commits its binding on Return.
/// This subclass writes every keystroke straight into the binding so the grid
/// filters live.
private final class HistorySearchFieldView: NSSearchField, NSSearchFieldDelegate {
    var onChange: ((String) -> Void)?
    private var lastValue = ""
    nonisolated(unsafe) private var pollTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Self-target and self-delegate cover the normal AppKit path. This
        // hosting view does not deliver those callbacks while typing, so a
        // light poll of the field value keeps the grid filtering live.
        target = self
        action = #selector(handleAction)
        delegate = self
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) {
            [weak self] _ in
            self?.poll()
        }
    }

    deinit {
        pollTimer?.invalidate()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func controlTextDidChange(_ notification: Notification) {
        publish(stringValue)
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        publish(stringValue)
    }

    @objc private func handleAction() {
        publish(stringValue)
    }

    private func poll() {
        publish(stringValue)
    }

    private func publish(_ value: String) {
        guard value != lastValue else { return }
        lastValue = value
        onChange?(value)
    }
}

private struct HistorySearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeNSView(context: Context) -> HistorySearchFieldView {
        let field = HistorySearchFieldView()
        field.placeholderString = placeholder
        field.controlSize = .small
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        let binding = $text
        field.onChange = { binding.wrappedValue = $0 }
        return field
    }

    func updateNSView(_ field: HistorySearchFieldView, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
    }
}
