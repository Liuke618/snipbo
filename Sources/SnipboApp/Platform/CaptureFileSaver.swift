import CoreGraphics
import Foundation
import SnipboCore

/// Writes captures into the save directory. Shared by the editor's save and
/// the direct auto-save path so file naming cannot drift.
enum CaptureFileSaver {
    /// Serializes the name check + write so two captures finishing in the same
    /// second cannot both pick the same file name.
    private static let writeLock = NSLock()

    static func defaultFileName(format: ImageFormat) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let ext = format == .png ? "png" : "jpg"
        return "Snipbo-\(formatter.string(from: Date())).\(ext)"
    }

    static func write(_ image: CGImage, format: ImageFormat, quality: Double, directory: String) throws {
        try write(
            image,
            format: format,
            quality: quality,
            directory: URL(fileURLWithPath: directory),
            preferredName: defaultFileName(format: format),
            uniqueName: true
        )
    }

    /// Writes to an explicit URL chosen by the user; an existing file is
    /// replaced after the save panel's own overwrite confirmation.
    static func write(_ image: CGImage, to url: URL, format: ImageFormat, quality: Double) throws {
        try write(
            image,
            format: format,
            quality: quality,
            directory: url.deletingLastPathComponent(),
            preferredName: url.lastPathComponent,
            uniqueName: false
        )
    }

    private static func write(
        _ image: CGImage,
        format: ImageFormat,
        quality: Double,
        directory: URL,
        preferredName: String,
        uniqueName: Bool
    ) throws {
        let data = try encodedData(image, format: format, quality: quality)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        writeLock.lock()
        defer { writeLock.unlock() }
        let name = uniqueName
            ? ImageFileNaming.uniqueURL(in: directory, preferredName: preferredName).lastPathComponent
            : preferredName
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private static func encodedData(
        _ image: CGImage,
        format: ImageFormat,
        quality: Double
    ) throws -> Data {
        let data: Data?
        switch format {
        case .png:
            data = ImageExporter.pngData(from: image)
        case .jpeg:
            data = ImageExporter.jpegData(from: image, quality: quality)
        }
        guard let data else { throw EditorError.encodeFailed }
        return data
    }
}
