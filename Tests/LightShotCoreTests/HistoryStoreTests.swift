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

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LightShotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeImage() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return try #require(context.makeImage())
    }
}
