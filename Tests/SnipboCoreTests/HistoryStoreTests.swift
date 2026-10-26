import CoreGraphics
import Foundation
import Testing
@testable import SnipboCore

@Suite("HistoryStoreTests")
struct HistoryStoreTests {
    @Test func testRecordAndLoadEntry() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let entry = try await store.record(image: ImageData(try makeImage()), source: .region)
        let entries = await store.entries()
        #expect(entries.map(\.id) == [entry.id])
        let imageURL = await store.imageURL(for: entry)
        #expect(FileManager.default.fileExists(atPath: imageURL.path))
    }

    @Test func testRecordKeepsNewestEntryWhenByteCapIsTiny() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // The byte cap is soft: even when the single entry alone exceeds it,
        // `record` must return an entry that is still present and stored.
        let store = HistoryStore(
            baseDirectory: directory,
            maxItems: 10,
            maxBytes: 1,
            minimumBytes: 1
        )
        let entry = try await store.record(image: ImageData(try makeImage(variant: 3)), source: .region)

        let entries = await store.entries()
        #expect(entries.map(\.id) == [entry.id])
        let imageURL = await store.imageURL(for: entry)
        let thumbnailURL = await store.thumbnailURL(for: entry)
        #expect(FileManager.default.fileExists(atPath: imageURL.path))
        #expect(FileManager.default.fileExists(atPath: thumbnailURL.path))
    }

    @Test func testPrunesByItemCount() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(baseDirectory: directory, maxItems: 2, maxBytes: 10 * 1024 * 1024)
        _ = try await store.record(image: ImageData(try makeImage()), source: .region)
        _ = try await store.record(image: ImageData(try makeImage()), source: .window)
        _ = try await store.record(image: ImageData(try makeImage()), source: .fullScreen)
        let entries = await store.entries()
        #expect(entries.count == 2)
    }

    @Test func testClearRemovesFiles() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        _ = try await store.record(image: ImageData(try makeImage()), source: .region)
        try await store.clear()
        let entries = await store.entries()
        #expect(entries.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files == ["index.json"])
    }

    @Test func testRemoveDeletesEntryAndFiles() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let removed = try await store.record(image: ImageData(try makeImage()), source: .region)
        let kept = try await store.record(image: ImageData(try makeImage(variant: 1)), source: .window)
        let removedImageURL = await store.imageURL(for: removed)
        let removedThumbnailURL = await store.thumbnailURL(for: removed)
        let keptImageURL = await store.imageURL(for: kept)

        try await store.remove(id: removed.id)

        let entries = await store.entries()
        #expect(entries.map(\.id) == [kept.id])
        #expect(!FileManager.default.fileExists(atPath: removedImageURL.path))
        #expect(!FileManager.default.fileExists(atPath: removedThumbnailURL.path))
        #expect(FileManager.default.fileExists(atPath: keptImageURL.path))

        let reloaded = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let reloadedEntries = await reloaded.entries()
        #expect(reloadedEntries.map(\.id) == [kept.id])
    }

    @Test func testUpdateLimitsPrunesAndPersists() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let first = try await store.record(image: ImageData(try makeImage()), source: .region)
        let second = try await store.record(image: ImageData(try makeImage(variant: 1)), source: .window)
        let third = try await store.record(image: ImageData(try makeImage(variant: 2)), source: .fullScreen)
        let firstImageURL = await store.imageURL(for: first)

        try await store.updateLimits(maxItems: 2, maxBytes: 10 * 1024 * 1024)

        let entries = await store.entries()
        #expect(entries.map(\.id) == [third.id, second.id])
        #expect(!FileManager.default.fileExists(atPath: firstImageURL.path))

        let reloaded = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let reloadedEntries = await reloaded.entries()
        #expect(reloadedEntries.map(\.id) == [third.id, second.id])
    }

    @Test func testSecondStoreReloadsValidEntries() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let first = try await store.record(image: ImageData(try makeImage()), source: .region)
        let second = try await store.record(image: ImageData(try makeImage(variant: 1)), source: .window)

        let reloaded = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let entries = await reloaded.entries()
        #expect(entries.map(\.id) == [second.id, first.id])
        #expect(entries.map(\.source) == [.window, .region])
        let imageURL = await reloaded.imageURL(for: second)
        #expect(FileManager.default.fileExists(atPath: imageURL.path))
    }

    @Test func testInitDropsEntryWhoseImageFileIsMissing() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let entry = try await store.record(image: ImageData(try makeImage()), source: .region)
        let imageURL = await store.imageURL(for: entry)
        let thumbnailURL = await store.thumbnailURL(for: entry)
        try FileManager.default.removeItem(at: imageURL)

        let reloaded = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let entries = await reloaded.entries()
        #expect(entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: thumbnailURL.path))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(Set(files) == ["index.json"])
    }

    @Test func testInitRemovesOnlyAppGeneratedOrphanFiles() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let entry = try await store.record(image: ImageData(try makeImage()), source: .region)
        let imageURL = await store.imageURL(for: entry)
        let orphanURL = directory.appendingPathComponent("\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: orphanURL)
        let unrelatedURL = directory.appendingPathComponent("notes.txt")
        try Data("keep me".utf8).write(to: unrelatedURL)

        let reloaded = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let entries = await reloaded.entries()
        #expect(entries.map(\.id) == [entry.id])
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
        #expect(FileManager.default.fileExists(atPath: unrelatedURL.path))
        #expect(FileManager.default.fileExists(atPath: imageURL.path))
    }

    @Test func testInitPrunesLoadedEntriesToLimits() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let first = try await store.record(image: ImageData(try makeImage()), source: .region)
        let second = try await store.record(image: ImageData(try makeImage(variant: 1)), source: .window)
        let third = try await store.record(image: ImageData(try makeImage(variant: 2)), source: .fullScreen)
        let firstImageURL = await store.imageURL(for: first)

        let reloaded = HistoryStore(baseDirectory: directory, maxItems: 2, maxBytes: 10 * 1024 * 1024)
        let entries = await reloaded.entries()
        #expect(entries.map(\.id) == [third.id, second.id])
        #expect(!FileManager.default.fileExists(atPath: firstImageURL.path))
    }

    @Test func testByteCapEvictsMultipleEntriesAndTheirFiles() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let first = try await store.record(image: ImageData(try makeImage()), source: .region)
        let second = try await store.record(image: ImageData(try makeImage(variant: 1)), source: .region)
        let third = try await store.record(image: ImageData(try makeImage(variant: 2)), source: .region)
        let fourth = try await store.record(image: ImageData(try makeImage(variant: 3)), source: .region)

        // A cap that fits exactly the two newest entries must evict both older
        // entries, including their image and thumbnail files.
        let cap = fileBytes(for: fourth, in: directory) + fileBytes(for: third, in: directory)
        let firstImageURL = await store.imageURL(for: first)
        let secondImageURL = await store.imageURL(for: second)
        let firstThumbnailURL = await store.thumbnailURL(for: first)
        let secondThumbnailURL = await store.thumbnailURL(for: second)

        let reloaded = HistoryStore(
            baseDirectory: directory,
            maxItems: 10,
            maxBytes: cap,
            minimumBytes: 1
        )
        let entries = await reloaded.entries()
        #expect(entries.map(\.id) == [fourth.id, third.id])
        let thirdImageURL = await reloaded.imageURL(for: third)
        let fourthImageURL = await reloaded.imageURL(for: fourth)
        #expect(FileManager.default.fileExists(atPath: thirdImageURL.path))
        #expect(FileManager.default.fileExists(atPath: fourthImageURL.path))
        #expect(!FileManager.default.fileExists(atPath: firstImageURL.path))
        #expect(!FileManager.default.fileExists(atPath: secondImageURL.path))
        #expect(!FileManager.default.fileExists(atPath: firstThumbnailURL.path))
        #expect(!FileManager.default.fileExists(atPath: secondThumbnailURL.path))
    }

    @Test func testCorruptIndexRecoversEntriesAndQuarantinesIndex() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let entry = try await store.record(image: ImageData(try makeImage()), source: .region)
        let imageURL = await store.imageURL(for: entry)
        let thumbnailURL = await store.thumbnailURL(for: entry)
        let indexPath = directory.appendingPathComponent("index.json")
        try Data("{ definitely not a history index".utf8).write(to: indexPath)

        let reloaded = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let entries = await reloaded.entries()

        #expect(entries.map(\.id) == [entry.id])
        #expect(entries.first?.source == .unknown)
        #expect(entries.first?.pixelWidth == 4)
        #expect(entries.first?.pixelHeight == 4)
        #expect(FileManager.default.fileExists(atPath: imageURL.path))
        #expect(FileManager.default.fileExists(atPath: thumbnailURL.path))
        // Recovery writes a new index that references the preserved files, so
        // the next launch cannot sweep them as orphans.
        #expect(FileManager.default.fileExists(atPath: indexPath.path))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.contains { $0.hasPrefix("index.corrupt-") && $0.hasSuffix(".json") })

        try await reloaded.updateLimits(maxItems: 10, maxBytes: 10 * 1024 * 1024)
        #expect(FileManager.default.fileExists(atPath: indexPath.path))
        #expect(FileManager.default.fileExists(atPath: imageURL.path))
        #expect(FileManager.default.fileExists(atPath: thumbnailURL.path))
    }

    @Test func testMissingIndexRecoversEntriesAndWritesIndex() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let entry = try await store.record(image: ImageData(try makeImage()), source: .region)
        let imageURL = await store.imageURL(for: entry)
        let thumbnailURL = await store.thumbnailURL(for: entry)
        let indexPath = directory.appendingPathComponent("index.json")
        try FileManager.default.removeItem(at: indexPath)

        let reloaded = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let entries = await reloaded.entries()

        #expect(entries.map(\.id) == [entry.id])
        #expect(entries.first?.source == .unknown)
        #expect(FileManager.default.fileExists(atPath: imageURL.path))
        #expect(FileManager.default.fileExists(atPath: thumbnailURL.path))
        #expect(FileManager.default.fileExists(atPath: indexPath.path))
    }

    @Test func testRecoveredEntriesSurviveTheNextRecord() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let old = try await store.record(image: ImageData(try makeImage()), source: .region)
        let indexPath = directory.appendingPathComponent("index.json")
        try FileManager.default.removeItem(at: indexPath)

        let recovered = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        _ = await recovered.entries()
        let new = try await recovered.record(image: ImageData(try makeImage(variant: 1)), source: .window)

        let reloaded = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let entries = await reloaded.entries()
        #expect(entries.map(\.id) == [new.id, old.id])
        let oldImageURL = await reloaded.imageURL(for: old)
        #expect(FileManager.default.fileExists(atPath: oldImageURL.path))
    }

    @Test func testRecoveryRegeneratesMissingThumbnail() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let entry = try await store.record(image: ImageData(try makeImage()), source: .region)
        let thumbnailURL = await store.thumbnailURL(for: entry)
        try FileManager.default.removeItem(at: thumbnailURL)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("index.json"))

        let reloaded = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let entries = await reloaded.entries()
        #expect(entries.map(\.id) == [entry.id])
        #expect(FileManager.default.fileExists(atPath: thumbnailURL.path))
    }

    @Test func testEmptyIndexWithRecoveryAllowedStillAdoptsImages() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let entry = try await store.record(image: ImageData(try makeImage()), source: .region)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let emptyIndex = HistoryIndex(
            version: HistoryIndex.currentVersion,
            entries: [],
            allowRecovery: true
        )
        try encoder.encode(emptyIndex).write(
            to: directory.appendingPathComponent("index.json")
        )

        let reloaded = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let entries = await reloaded.entries()
        #expect(entries.map(\.id) == [entry.id])
    }

    @Test func testRemovingLastEntryDoesNotRecoverLeftoverImage() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let entry = try await store.record(image: ImageData(try makeImage()), source: .region)
        try await store.remove(id: entry.id)

        let leftoverURL = directory.appendingPathComponent("\(UUID().uuidString).png")
        let png = try #require(ImageExporter.pngData(from: try makeImage()))
        try png.write(to: leftoverURL)

        let reloaded = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let entries = await reloaded.entries()
        #expect(entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: leftoverURL.path))
    }

    @Test func testClearTombstoneSweepsLeftoverImagesInsteadOfRecovering() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        _ = try await store.record(image: ImageData(try makeImage()), source: .region)
        try await store.clear()

        // Simulate an image that clear could not delete.
        let leftoverURL = directory.appendingPathComponent("\(UUID().uuidString).png")
        let png = try #require(ImageExporter.pngData(from: try makeImage()))
        try png.write(to: leftoverURL)

        let reloaded = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let entries = await reloaded.entries()
        #expect(entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: leftoverURL.path))
        let data = try Data(contentsOf: directory.appendingPathComponent("index.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let index = try decoder.decode(HistoryIndex.self, from: data)
        #expect(index.allowRecovery == false)
    }

    @Test func testNewIndexHasSchemaVersion() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        _ = try await store.record(image: ImageData(try makeImage()), source: .region)

        let data = try Data(contentsOf: directory.appendingPathComponent("index.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let index = try decoder.decode(HistoryIndex.self, from: data)
        #expect(index.version == HistoryIndex.currentVersion)
        #expect(index.entries.count == 1)
    }

    @Test func testLegacyArrayIndexStillLoads() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let entry = try await store.record(image: ImageData(try makeImage()), source: .region)
        let entries = await store.entries()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacy = try encoder.encode(entries)
        try legacy.write(to: directory.appendingPathComponent("index.json"))

        let reloaded = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let loaded = await reloaded.entries()
        #expect(loaded.map(\.id) == [entry.id])
    }

    @Test func testUnsafeIndexFilenamesAreDroppedAndCannotDeleteOutsideFiles() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outsideURL = directory.deletingLastPathComponent()
            .appendingPathComponent("snipbo-outside-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: outsideURL) }
        try Data([0]).write(to: outsideURL)

        let unsafe = HistoryEntry(
            id: UUID(),
            createdAt: Date(),
            pixelWidth: 1,
            pixelHeight: 1,
            source: .region,
            imageFileName: "../\(outsideURL.lastPathComponent)",
            thumbnailFileName: "../\(outsideURL.lastPathComponent)"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([unsafe]).write(to: directory.appendingPathComponent("index.json"))

        let store = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let entries = await store.entries()
        #expect(entries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: outsideURL.path))
    }

    private func fileBytes(for entry: HistoryEntry, in directory: URL) -> Int64 {
        let imageBytes = fileSize(directory.appendingPathComponent(entry.imageFileName))
        let thumbnailBytes = fileSize(directory.appendingPathComponent(entry.thumbnailFileName))
        return imageBytes + thumbnailBytes
    }

    private func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipboTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeImage(width: Int = 4, height: Int = 4, variant: Int = 0) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Per-column stripes keep the bitmap non-uniform so its PNG cannot
        // compress to a trivial size.
        for x in 0..<width {
            let red = CGFloat((x * 37 + variant * 101) % 256) / 255
            let green = CGFloat((x * 53 + variant * 149) % 256) / 255
            let blue = CGFloat((x * 97 + variant * 211) % 256) / 255
            context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        return try #require(context.makeImage())
    }
}
