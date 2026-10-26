import CoreGraphics
import Foundation
import ImageIO
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

/// Versioned on-disk index. Older builds wrote a bare `[HistoryEntry]` array;
/// `loadState` still accepts that shape so upgrades do not lose history.
struct HistoryIndex: Codable {
    static let currentVersion = 1
    var version: Int
    var entries: [HistoryEntry]
    /// False after an explicit clear: leftover image files are swept instead
    /// of being adopted as recovered entries on the next launch.
    var allowRecovery: Bool? = nil
}

public actor HistoryStore {
    private static let logger = Logger(subsystem: "local.snipbo.app", category: "History")
    private let baseDirectory: URL
    private let minimumBytes: Int64
    private var maxItems: Int
    private var maxBytes: Int64
    private var entriesValue: [HistoryEntry] = []
    /// False until a valid index has been loaded or written in this process.
    /// While false, an empty list must not be persisted: an empty index would
    /// tell the next launch that every preserved image is an orphan.
    private var hasTrustworthyIndex = false
    /// False after an explicit clear, so an empty tombstone index does not
    /// resurrect files that could not be deleted.
    private var allowRecovery = true
    /// Loading touches the index and every image file; it runs on the actor's
    /// executor the first time the store is used instead of on the caller
    /// (which used to be the main thread at app launch).
    private var loaded = false
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
        self.maxItems = max(1, maxItems)
        self.maxBytes = max(max(0, minimumBytes), maxBytes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    public func entries() -> [HistoryEntry] {
        ensureLoaded()
        return entriesValue
    }

    /// The store's private directory. Immutable, so UI code can resolve cached
    /// entries for a file-existence check without an actor hop.
    public nonisolated var directory: URL {
        baseDirectory
    }

    public func imageURL(for entry: HistoryEntry) -> URL {
        safeURL(for: entry.imageFileName)
    }

    public func thumbnailURL(for entry: HistoryEntry) -> URL {
        safeURL(for: entry.thumbnailFileName)
    }

    public func updateLimits(maxItems: Int, maxBytes: Int64) throws {
        ensureLoaded()
        self.maxItems = max(1, maxItems)
        self.maxBytes = max(minimumBytes, maxBytes)
        try prune(forceSave: false)
    }

    public func record(image: ImageData, source: CaptureSource) throws -> HistoryEntry {
        ensureLoaded()
        allowRecovery = true
        let id = UUID()
        let imageFileName = "\(id.uuidString).png"
        let thumbnailFileName = "\(id.uuidString)-thumb.png"
        guard let png = ImageExporter.pngData(from: image.cgImage),
              let thumbnail = makeThumbnail(image.cgImage),
              let thumbnailData = ImageExporter.pngData(from: thumbnail) else {
            throw HistoryError.encodeFailed
        }
        let imageURL = baseDirectory.appendingPathComponent(imageFileName)
        let thumbnailURL = baseDirectory.appendingPathComponent(thumbnailFileName)
        try png.write(to: imageURL, options: .atomic)
        do {
            try thumbnailData.write(to: thumbnailURL, options: .atomic)
        } catch {
            // Do not leave the full image behind when its pair could not be
            // written.
            try? fileManager.removeItem(at: imageURL)
            throw error
        }
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
            try prune(forceSave: true)
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
        ensureLoaded()
        guard let index = entriesValue.firstIndex(where: { $0.id == id }) else { return }
        let entry = entriesValue.remove(at: index)
        let previousRecovery = allowRecovery
        if entriesValue.isEmpty {
            // Removing the last entry must not let a leftover image be
            // recovered as if it were still part of the history.
            allowRecovery = false
        }
        do {
            try saveIndex(entriesValue)
        } catch {
            entriesValue.insert(entry, at: index)
            allowRecovery = previousRecovery
            throw error
        }
        removeFiles(for: entry)
    }

    public func clear() throws {
        // Write the tombstone first: if an image cannot be deleted, the next
        // launch must sweep it rather than recover it as a cleared capture.
        // Only mutate the in-memory list after the tombstone succeeds, so a
        // failed clear does not make the UI pretend the history is empty.
        try writeIndex([], allowRecovery: false)
        hasTrustworthyIndex = true
        loaded = true
        entriesValue.removeAll()
        allowRecovery = false
        let files = (try? fileManager.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent != Self.indexFileName {
            try? fileManager.removeItem(at: file)
        }
    }

    // MARK: - Lazy load

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        let state = Self.loadState(
            baseDirectory: baseDirectory,
            maxItems: maxItems,
            maxBytes: maxBytes,
            decoder: decoder,
            fileManager: fileManager
        )
        entriesValue = state.entries
        hasTrustworthyIndex = state.indexIsTrustworthy
        allowRecovery = state.allowRecovery
        if state.indexNeedsRewrite {
            do {
                try writeIndex(state.entries, allowRecovery: state.allowRecovery)
                hasTrustworthyIndex = true
            } catch {
                Self.logger.error(
                    "Failed to rewrite the history index: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    private func writeIndex(_ entries: [HistoryEntry], allowRecovery: Bool) throws {
        let index = HistoryIndex(
            version: HistoryIndex.currentVersion,
            entries: entries,
            allowRecovery: allowRecovery
        )
        let data = try encoder.encode(index)
        try data.write(to: indexURL, options: .atomic)
    }

    private func saveIndex(_ entries: [HistoryEntry]) throws {
        guard !entries.isEmpty || hasTrustworthyIndex else {
            // No valid index was loaded and there is nothing to reference the
            // preserved files. Writing `[]` would make the next launch sweep
            // them as orphans, so leave the directory alone until a record
            // writes a real index.
            return
        }
        let recovery = entries.isEmpty ? allowRecovery : true
        try writeIndex(entries, allowRecovery: recovery)
        allowRecovery = recovery
        hasTrustworthyIndex = true
    }

    private func prune(forceSave: Bool) throws {
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
        // Avoid rewriting index.json for every unrelated settings change. A
        // record forces the write so the new entry is persisted.
        if forceSave || !removed.isEmpty || !hasTrustworthyIndex {
            // Write the index once, and only then delete files. Until the write
            // succeeds the in-memory list stays consistent with the on-disk index.
            try saveIndex(kept)
        }
        entriesValue = kept
        for entry in removed {
            removeFiles(for: entry)
        }
    }

    private func safeURL(for fileName: String) -> URL {
        let safeName = Self.isSafeFileName(fileName) ? fileName : "__invalid__"
        return baseDirectory.appendingPathComponent(safeName)
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
        var allowRecovery: Bool
    }

    /// Loads `index.json`, drops entries whose image file is gone, prunes the
    /// survivors to the limits, and removes store files that no surviving
    /// entry references. Only files directly inside `baseDirectory` are
    /// touched, and only names this store generated are swept.
    ///
    /// A missing or corrupt index is recovered from the UUID-named image files
    /// themselves: the previous build only preserved the files, which made the
    /// history appear empty and let the next launch sweep them once a new
    /// record wrote a replacement index. Recovery writes an index that
    /// references the recovered entries, so they remain visible and safe.
    private static func loadState(
        baseDirectory: URL,
        maxItems: Int,
        maxBytes: Int64,
        decoder: JSONDecoder,
        fileManager: FileManager
    ) -> LoadedState {
        let indexPath = baseDirectory.appendingPathComponent(indexFileName)
        guard fileManager.fileExists(atPath: indexPath.path) else {
            return recoveredState(
                baseDirectory: baseDirectory,
                maxItems: maxItems,
                maxBytes: maxBytes,
                fileManager: fileManager
            )
        }

        let decoded: [HistoryEntry]
        var allowRecovery = true
        do {
            let data = try Data(contentsOf: indexPath)
            if let index = try? decoder.decode(HistoryIndex.self, from: data) {
                decoded = index.entries
                allowRecovery = index.allowRecovery ?? true
            } else {
                decoded = try decoder.decode([HistoryEntry].self, from: data)
            }
        } catch {
            quarantineIndex(
                at: indexPath,
                in: baseDirectory,
                fileManager: fileManager,
                error: error
            )
            return recoveredState(
                baseDirectory: baseDirectory,
                maxItems: maxItems,
                maxBytes: maxBytes,
                fileManager: fileManager
            )
        }

        let safeEntries = decoded.filter {
            isSafeFileName($0.imageFileName) && isSafeFileName($0.thumbnailFileName)
        }
        var entries = safeEntries
        var indexNeedsRewrite = safeEntries.count != decoded.count

        // An old build could write an empty index while images were still on
        // disk. Adopt them instead of treating them as orphans, unless an
        // explicit clear left a tombstone.
        if entries.isEmpty, allowRecovery {
            let recovered = recoverEntries(in: baseDirectory, fileManager: fileManager)
            if !recovered.isEmpty {
                entries = recovered
                indexNeedsRewrite = true
            }
        }
        if !entries.isEmpty {
            // Once real entries exist, future loads should be able to recover.
            allowRecovery = true
        }

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
            indexIsTrustworthy: true,
            allowRecovery: allowRecovery
        )
    }

    /// Rebuilds entries from the image files when no usable index exists.
    private static func recoveredState(
        baseDirectory: URL,
        maxItems: Int,
        maxBytes: Int64,
        fileManager: FileManager
    ) -> LoadedState {
        let recovered = recoverEntries(in: baseDirectory, fileManager: fileManager)
        guard !recovered.isEmpty else {
            // No index and no recognizable images: keep unknown files for a
            // later diagnosis instead of sweeping the directory.
            return LoadedState(
                entries: [],
                indexNeedsRewrite: false,
                indexIsTrustworthy: false,
                allowRecovery: true
            )
        }
        let kept = survivors(
            of: recovered,
            maxItems: maxItems,
            maxBytes: maxBytes,
            in: baseDirectory,
            fileManager: fileManager
        )
        _ = removeOrphanFiles(referencedBy: kept, in: baseDirectory, fileManager: fileManager)
        return LoadedState(
            entries: kept,
            indexNeedsRewrite: true,
            indexIsTrustworthy: true,
            allowRecovery: true
        )
    }

    private static func recoverEntries(
        in baseDirectory: URL,
        fileManager: FileManager
    ) -> [HistoryEntry] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey, .contentModificationDateKey]
        )) ?? []
        var entries: [HistoryEntry] = []
        for url in contents {
            let name = url.lastPathComponent
            guard let id = imageID(from: name) else { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                continue
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0, height > 0 else {
                continue
            }
            let stem = String(name.dropLast(4))
            let thumbnailFileName = "\(stem)-thumb.png"
            let thumbnailURL = baseDirectory.appendingPathComponent(thumbnailFileName)
            if !fileManager.fileExists(atPath: thumbnailURL.path) {
                writeThumbnail(from: source, to: thumbnailURL)
            }
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let createdAt = values?.creationDate ?? values?.contentModificationDate ?? Date()
            entries.append(HistoryEntry(
                id: id,
                createdAt: createdAt,
                pixelWidth: width,
                pixelHeight: height,
                source: .unknown,
                imageFileName: name,
                thumbnailFileName: thumbnailFileName
            ))
        }
        return entries.sorted { $0.createdAt > $1.createdAt }
    }

    private static func writeThumbnail(from source: CGImageSource, to url: URL) {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ), let data = ImageExporter.pngData(from: thumbnail) else { return }
        try? data.write(to: url, options: .atomic)
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
            // Only the UUID-named images this store writes are ours to remove.
            // A user file or a quarantined corrupt index must survive.
            guard isAppGeneratedImageFileName(name) else { continue }
            // Never descend into or delete directories.
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                continue
            }
            guard !referenced.contains(name) else { continue }
            try? fileManager.removeItem(at: url)
            removedAny = true
        }
        return removedAny
    }

    // MARK: - Names

    private static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\\")
            && (name as NSString).lastPathComponent == name
    }

    private static func imageID(from name: String) -> UUID? {
        guard name.hasSuffix(".png"), !name.hasSuffix("-thumb.png") else { return nil }
        return UUID(uuidString: String(name.dropLast(4)))
    }

    private static func isAppGeneratedImageFileName(_ name: String) -> Bool {
        if imageID(from: name) != nil { return true }
        guard name.hasSuffix("-thumb.png") else { return false }
        let stem = String(name.dropLast("-thumb.png".count))
        return UUID(uuidString: stem) != nil
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
