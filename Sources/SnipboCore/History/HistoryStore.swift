import CoreGraphics
import Foundation
import os

public enum HistoryError: Error, LocalizedError {
    case encodeFailed

    public var errorDescription: String? {
        switch self {
        case .encodeFailed:
            return "The screenshot could not be encoded for the history."
        }
    }
}

public actor HistoryStore {
    private static let logger = Logger(subsystem: "local.snipbo.app", category: "History")
    private let baseDirectory: URL
    private let minimumBytes: Int64
    private var maxItems: Int
    private var maxBytes: Int64
    private var entriesValue: [HistoryEntry]
    /// False until a valid index has been loaded or written in this process.
    /// While false, an empty list must not be persisted: an empty index would
    /// tell the next launch that every preserved image is an orphan.
    private var hasTrustworthyIndex = false
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var indexURL: URL { baseDirectory.appendingPathComponent(Self.indexFileName) }

    /// Production floor for the byte cap.
    private static let defaultMinimumBytes: Int64 = 10 * 1024 * 1024
    private static let indexFileName = "index.json"

    public init(baseDirectory: URL, maxItems: Int, maxBytes: Int64) {
        self.init(
            baseDirectory: baseDirectory,
            maxItems: maxItems,
            maxBytes: maxBytes,
            minimumBytes: Self.defaultMinimumBytes
        )
    }

    /// Internal test seam: lets tests exercise byte-cap pruning with caps below
    /// the production floor. Production callers use the public initializer,
    /// whose floor defaults to 10 MiB.
    init(baseDirectory: URL, maxItems: Int, maxBytes: Int64, minimumBytes: Int64 = 10 * 1024 * 1024) {
        self.baseDirectory = baseDirectory
        self.minimumBytes = max(0, minimumBytes)
        let clampedMaxItems = max(1, maxItems)
        let clampedMaxBytes = max(max(0, minimumBytes), maxBytes)
        self.maxItems = clampedMaxItems
        self.maxBytes = clampedMaxBytes
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let loaded = Self.loadState(
            baseDirectory: baseDirectory,
            maxItems: clampedMaxItems,
            maxBytes: clampedMaxBytes,
            decoder: decoder,
            fileManager: fileManager
        )
        self.entriesValue = loaded.entries
        self.hasTrustworthyIndex = loaded.indexIsTrustworthy
        if loaded.indexNeedsRewrite {
            do {
                let data = try encoder.encode(loaded.entries)
                try data.write(
                    to: baseDirectory.appendingPathComponent(Self.indexFileName),
                    options: .atomic
                )
                self.hasTrustworthyIndex = true
            } catch {
                Self.logger.error(
                    "Failed to rewrite the history index: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    public func entries() -> [HistoryEntry] {
        entriesValue
    }

    /// The store's private directory. Immutable, so UI code can resolve cached
    /// entries for a file-existence check without an actor hop.
    public nonisolated var directory: URL {
        baseDirectory
    }

    public func imageURL(for entry: HistoryEntry) -> URL {
        baseDirectory.appendingPathComponent(entry.imageFileName)
    }

    public func thumbnailURL(for entry: HistoryEntry) -> URL {
        baseDirectory.appendingPathComponent(entry.thumbnailFileName)
    }

    public func updateLimits(maxItems: Int, maxBytes: Int64) throws {
        self.maxItems = max(1, maxItems)
        self.maxBytes = max(minimumBytes, maxBytes)
        try prune()
    }

    public func record(image: ImageData, source: CaptureSource) throws -> HistoryEntry {
        let id = UUID()
        let imageFileName = "\(id.uuidString).png"
        let thumbnailFileName = "\(id.uuidString)-thumb.png"
        guard let png = ImageExporter.pngData(from: image.cgImage),
              let thumbnail = makeThumbnail(image.cgImage),
              let thumbnailData = ImageExporter.pngData(from: thumbnail) else {
            throw HistoryError.encodeFailed
        }
        try png.write(to: baseDirectory.appendingPathComponent(imageFileName), options: .atomic)
        try thumbnailData.write(to: baseDirectory.appendingPathComponent(thumbnailFileName), options: .atomic)
        let entry = HistoryEntry(
            id: id,
            createdAt: Date(),
            pixelWidth: image.cgImage.width,
            pixelHeight: image.cgImage.height,
            source: source,
            imageFileName: imageFileName,
            thumbnailFileName: thumbnailFileName
        )
        entriesValue.insert(entry, at: 0)
        do {
            try prune()
        } catch {
            // The index was not rewritten, so restore the pre-record state.
            entriesValue.removeAll { $0.id == entry.id }
            removeFiles(for: entry)
            throw error
        }
        assert(
            entriesValue.contains { $0.id == entry.id },
            "record must not return an entry that pruning removed"
        )
        return entry
    }

    public func remove(id: UUID) throws {
        guard let index = entriesValue.firstIndex(where: { $0.id == id }) else { return }
        let entry = entriesValue.remove(at: index)
        do {
            try saveIndex(entriesValue)
        } catch {
            entriesValue.insert(entry, at: index)
            throw error
        }
        removeFiles(for: entry)
    }

    public func clear() throws {
        entriesValue.removeAll()
        let files = (try? fileManager.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            try? fileManager.removeItem(at: file)
        }
    }

    private func saveIndex(_ entries: [HistoryEntry]) throws {
        guard !entries.isEmpty || hasTrustworthyIndex else {
            // No valid index was loaded and there is nothing to reference the
            // preserved files. Writing `[]` would make the next launch sweep
            // them as orphans, so leave the directory alone until a record
            // writes a real index.
            return
        }
        let data = try encoder.encode(entries)
        try data.write(to: indexURL, options: .atomic)
        hasTrustworthyIndex = true
    }

    private func prune() throws {
        let kept = Self.survivors(
            of: entriesValue,
            maxItems: maxItems,
            maxBytes: maxBytes,
            in: baseDirectory,
            fileManager: fileManager
        )
        // Survivors are always a prefix of the newest-first array, so the
        // removed entries are its tail.
        let removed = Array(entriesValue.dropFirst(kept.count))
        // Write the index once, and only then delete files. Until the write
        // succeeds the in-memory list stays consistent with the on-disk index.
        try saveIndex(kept)
        entriesValue = kept
        for entry in removed {
            removeFiles(for: entry)
        }
    }

    private func removeFiles(for entry: HistoryEntry) {
        try? fileManager.removeItem(at: imageURL(for: entry))
        try? fileManager.removeItem(at: thumbnailURL(for: entry))
    }

    // MARK: - Startup reconciliation

    private struct LoadedState {
        var entries: [HistoryEntry]
        var indexNeedsRewrite: Bool
        var indexIsTrustworthy: Bool
    }

    /// Loads `index.json`, drops entries whose image file is gone, prunes the
    /// survivors to the limits, and removes store files that no surviving
    /// entry references. Only files directly inside `baseDirectory` are
    /// touched; `index.json` is never deleted by the orphan sweep (an
    /// unreadable index is moved aside by `quarantineIndex`).
    ///
    /// A missing index or an index that cannot be decoded must never trigger
    /// the orphan sweep: without a trustworthy index every image looks
    /// unreferenced, and sweeping would delete the user's whole history. A
    /// corrupt index is moved aside and no replacement is written until the
    /// next successful record, so a later launch cannot sweep the preserved
    /// files either.
    private static func loadState(
        baseDirectory: URL,
        maxItems: Int,
        maxBytes: Int64,
        decoder: JSONDecoder,
        fileManager: FileManager
    ) -> LoadedState {
        let indexPath = baseDirectory.appendingPathComponent(indexFileName)
        guard fileManager.fileExists(atPath: indexPath.path) else {
            // No index: there is no way to tell which files belong to the
            // store, so keep them all and do not create an empty index.
            return LoadedState(entries: [], indexNeedsRewrite: false, indexIsTrustworthy: false)
        }

        let decoded: [HistoryEntry]
        do {
            let data = try Data(contentsOf: indexPath)
            decoded = try decoder.decode([HistoryEntry].self, from: data)
        } catch {
            quarantineIndex(
                at: indexPath,
                in: baseDirectory,
                fileManager: fileManager,
                error: error
            )
            return LoadedState(entries: [], indexNeedsRewrite: false, indexIsTrustworthy: false)
        }

        var entries = decoded
        var indexNeedsRewrite = false
        let existing = entries.filter { entry in
            fileManager.fileExists(
                atPath: baseDirectory.appendingPathComponent(entry.imageFileName).path
            )
        }
        if existing.count != entries.count {
            entries = existing
            indexNeedsRewrite = true
        }

        let kept = survivors(
            of: entries,
            maxItems: maxItems,
            maxBytes: maxBytes,
            in: baseDirectory,
            fileManager: fileManager
        )
        if kept.count != entries.count {
            entries = kept
            indexNeedsRewrite = true
        }

        if removeOrphanFiles(referencedBy: entries, in: baseDirectory, fileManager: fileManager) {
            indexNeedsRewrite = true
        }

        return LoadedState(
            entries: entries,
            indexNeedsRewrite: indexNeedsRewrite,
            indexIsTrustworthy: true
        )
    }

    /// Moves an unreadable `index.json` out of the way so the next load sees
    /// "no index" instead of decoding the same failure again. A read-only
    /// directory can make the rename fail; log that and leave the file alone.
    private static func quarantineIndex(
        at indexPath: URL,
        in baseDirectory: URL,
        fileManager: FileManager,
        error: Error
    ) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stamp = formatter.string(from: Date())
        let quarantineURL = baseDirectory
            .appendingPathComponent("index.corrupt-\(stamp).json")
        do {
            try fileManager.moveItem(at: indexPath, to: quarantineURL)
            logger.error(
                "History index was unreadable and was moved to \(quarantineURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        } catch {
            logger.error(
                "History index is unreadable and could not be quarantined: \(String(describing: error), privacy: .public)"
            )
        }
    }

    @discardableResult
    private static func removeOrphanFiles(
        referencedBy entries: [HistoryEntry],
        in baseDirectory: URL,
        fileManager: FileManager
    ) -> Bool {
        var referenced = Set<String>()
        for entry in entries {
            referenced.insert(entry.imageFileName)
            referenced.insert(entry.thumbnailFileName)
        }
        let contents = (try? fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )) ?? []
        var removedAny = false
        for url in contents {
            let name = url.lastPathComponent
            guard name != indexFileName else { continue }
            // Never descend into or delete directories; the store owns only
            // the regular files it wrote directly into its private directory.
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                continue
            }
            guard !referenced.contains(name) else { continue }
            try? fileManager.removeItem(at: url)
            removedAny = true
        }
        return removedAny
    }

    // MARK: - Limits

    /// Computes the newest-first prefix that fits the limits. The item cap
    /// always leaves at least the newest entry, and the byte cap is soft: it
    /// never evicts the last remaining entry.
    private static func survivors(
        of entries: [HistoryEntry],
        maxItems: Int,
        maxBytes: Int64,
        in baseDirectory: URL,
        fileManager: FileManager
    ) -> [HistoryEntry] {
        var survivors = entries
        if survivors.count > maxItems {
            survivors.removeLast(survivors.count - maxItems)
        }
        var total = totalBytes(of: survivors, in: baseDirectory, fileManager: fileManager)
        while survivors.count > 1 && total > maxBytes {
            let removed = survivors.removeLast()
            total -= bytes(of: removed, in: baseDirectory, fileManager: fileManager)
        }
        return survivors
    }

    private static func totalBytes(
        of entries: [HistoryEntry],
        in baseDirectory: URL,
        fileManager: FileManager
    ) -> Int64 {
        entries.reduce(0) { partial, entry in
            partial + bytes(of: entry, in: baseDirectory, fileManager: fileManager)
        }
    }

    private static func bytes(
        of entry: HistoryEntry,
        in baseDirectory: URL,
        fileManager: FileManager
    ) -> Int64 {
        fileSize(
            of: baseDirectory.appendingPathComponent(entry.imageFileName),
            fileManager: fileManager
        ) + fileSize(
            of: baseDirectory.appendingPathComponent(entry.thumbnailFileName),
            fileManager: fileManager
        )
    }

    private static func fileSize(of url: URL, fileManager: FileManager) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func makeThumbnail(_ image: CGImage, maxDimension: CGFloat = 256) -> CGImage? {
        let scale = min(1, maxDimension / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
