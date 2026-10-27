import CoreGraphics
import Foundation
import SnipboCore

/// One persisted pin: its PNG and the last window frame in AppKit screen
/// coordinates.
struct PinnedItem: Codable, Identifiable, Sendable {
    let id: UUID
    let imageFileName: String
    var frame: CGRect
    let createdAt: Date
}

/// Stores pins under Application Support so they survive a relaunch. Pins are
/// still disposable: closing one deletes its file, and "close all" clears the
/// whole directory.
actor PinStore {
    nonisolated let directory: URL
    private var items: [PinnedItem] = []
    private var loaded = false
    private let indexURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directory: URL = AppPaths.pinsDirectory) {
        self.directory = directory
        self.indexURL = directory.appendingPathComponent("index.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func load() -> [PinnedItem] {
        ensureLoaded()
        return items
    }

    /// Writes the PNG and appends it to the index. The caller supplies the
    /// frame so the restored position matches what the user sees now.
    func save(image: CGImage, id: UUID, frame: CGRect) throws -> PinnedItem {
        ensureLoaded()
        guard let png = ImageExporter.pngData(from: image) else {
            throw PinStoreError.encodeFailed
        }
        let fileName = "\(id.uuidString).png"
        let url = directory.appendingPathComponent(fileName)
        try png.write(to: url, options: .atomic)
        let item = PinnedItem(
            id: id,
            imageFileName: fileName,
            frame: frame,
            createdAt: Date()
        )
        items.append(item)
        do {
            try saveIndex()
        } catch {
            items.removeAll { $0.id == id }
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return item
    }

    func updateFrame(id: UUID, frame: CGRect) throws {
        ensureLoaded()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].frame = frame
        try saveIndex()
    }

    func remove(id: UUID) throws {
        ensureLoaded()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: index)
        do {
            try saveIndex()
        } catch {
            items.insert(item, at: index)
            throw error
        }
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(item.imageFileName)
        )
    }

    func removeAll() throws {
        ensureLoaded()
        try saveIndex(forceEmpty: true)
        items.removeAll()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for file in files where file.lastPathComponent != "index.json" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? decoder.decode(PinIndex.self, from: data) else {
            return
        }
        items = index.items.filter {
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent($0.imageFileName).path
            )
        }
    }

    private func saveIndex(forceEmpty: Bool = false) throws {
        if items.isEmpty, !forceEmpty {
            // An empty list is still a valid state; write it so removals stick.
        }
        let index = PinIndex(version: PinIndex.currentVersion, items: items)
        let data = try encoder.encode(index)
        try data.write(to: indexURL, options: .atomic)
    }
}

private struct PinIndex: Codable {
    static let currentVersion = 1
    var version: Int
    var items: [PinnedItem]
}

enum PinStoreError: Error, LocalizedError {
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .encodeFailed:
            return L10n.tr("The pin could not be encoded.", "贴图编码失败。")
        }
    }
}
