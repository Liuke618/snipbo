import Foundation
import Testing
@testable import SnipboCore

@Suite("ImageFileNamingTests")
struct ImageFileNamingTests {
    @Test func testPreferredNameIsUsedWhenFree() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = ImageFileNaming.uniqueURL(in: directory, preferredName: "Snipbo-1.png")
        #expect(url.lastPathComponent == "Snipbo-1.png")
    }

    @Test func testTakenNameGetsCounterSuffix() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data([0]).write(to: directory.appendingPathComponent("Snipbo-1.png"))
        let second = ImageFileNaming.uniqueURL(in: directory, preferredName: "Snipbo-1.png")
        #expect(second.lastPathComponent == "Snipbo-1-2.png")

        try Data([0]).write(to: second)
        let third = ImageFileNaming.uniqueURL(in: directory, preferredName: "Snipbo-1.png")
        #expect(third.lastPathComponent == "Snipbo-1-3.png")
    }

    @Test func testCounterIsInsertedBeforeTheExtension() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data([0]).write(to: directory.appendingPathComponent("capture.jpeg"))
        let url = ImageFileNaming.uniqueURL(in: directory, preferredName: "capture.jpeg")
        #expect(url.lastPathComponent == "capture-2.jpeg")
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipboNamingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
