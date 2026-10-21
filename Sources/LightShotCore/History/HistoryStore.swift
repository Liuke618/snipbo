import CoreGraphics
import Foundation

public enum HistoryError: Error {
    case encodeFailed
}

public actor HistoryStore {
    private let baseDirectory: URL
    private var maxItems: Int
    private var maxBytes: Int64
    private var entriesValue: [HistoryEntry]
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var indexURL: URL { baseDirectory.appendingPathComponent("index.json") }

    public init(baseDirectory: URL, maxItems: Int, maxBytes: Int64) {
        self.baseDirectory = baseDirectory
        self.maxItems = max(1, maxItems)
        self.maxBytes = max(10 * 1024 * 1024, maxBytes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        var loadedEntries: [HistoryEntry] = []
        let indexPath = baseDirectory.appendingPathComponent("index.json")
        if let data = try? Data(contentsOf: indexPath),
           let loaded = try? decoder.decode([HistoryEntry].self, from: data) {
            loadedEntries = loaded
        }
        self.entriesValue = loadedEntries
    }

    public func entries() -> [HistoryEntry] {
        entriesValue
    }

    public func imageURL(for entry: HistoryEntry) -> URL {
        baseDirectory.appendingPathComponent(entry.imageFileName)
    }

    public func thumbnailURL(for entry: HistoryEntry) -> URL {
        baseDirectory.appendingPathComponent(entry.thumbnailFileName)
    }

    public func updateLimits(maxItems: Int, maxBytes: Int64) throws {
        self.maxItems = max(1, maxItems)
        self.maxBytes = max(10 * 1024 * 1024, maxBytes)
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
        try saveIndex()
        try prune()
        return entry
    }

    public func remove(id: UUID) throws {
        guard let index = entriesValue.firstIndex(where: { $0.id == id }) else { return }
        let entry = entriesValue.remove(at: index)
        try? fileManager.removeItem(at: imageURL(for: entry))
        try? fileManager.removeItem(at: thumbnailURL(for: entry))
        try saveIndex()
    }

    public func clear() throws {
        entriesValue.removeAll()
        let files = (try? fileManager.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            try? fileManager.removeItem(at: file)
        }
    }

    private func saveIndex() throws {
        let data = try encoder.encode(entriesValue)
        try data.write(to: indexURL, options: .atomic)
    }

    private func prune() throws {
        while entriesValue.count > maxItems || totalBytes() > maxBytes {
            guard let last = entriesValue.popLast() else { break }
            try? fileManager.removeItem(at: imageURL(for: last))
            try? fileManager.removeItem(at: thumbnailURL(for: last))
        }
        try saveIndex()
    }

    private func totalBytes() -> Int64 {
        entriesValue.reduce(0) { partial, entry in
            let imageAttributes = try? fileManager.attributesOfItem(atPath: imageURL(for: entry).path)
            let thumbAttributes = try? fileManager.attributesOfItem(atPath: thumbnailURL(for: entry).path)
            let imageSize = (imageAttributes?[.size] as? NSNumber)?.int64Value ?? 0
            let thumbSize = (thumbAttributes?[.size] as? NSNumber)?.int64Value ?? 0
            return partial + imageSize + thumbSize
        }
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
