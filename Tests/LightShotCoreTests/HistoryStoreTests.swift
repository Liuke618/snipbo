import CoreGraphics
import Foundation
import Testing
@testable import LightShotCore

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
        #expect(files.isEmpty)
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

    @Test func testInitRemovesOrphanFiles() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let entry = try await store.record(image: ImageData(try makeImage()), source: .region)
        let imageURL = await store.imageURL(for: entry)
        let orphanURL = directory.appendingPathComponent("orphan.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: orphanURL)

        let reloaded = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let entries = await reloaded.entries()
        #expect(entries.map(\.id) == [entry.id])
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
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

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LightShotTests-\(UUID().uuidString)", isDirectory: true)
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
