import CoreGraphics
import Foundation
import SnipboCore

/// Writes captures into the save directory. Shared by the editor's save and
/// the direct auto-save path so file naming cannot drift.
enum CaptureFileSaver {
    static func defaultFileName(format: ImageFormat) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let ext = format == .png ? "png" : "jpg"
        return "Snipbo-\(formatter.string(from: Date())).\(ext)"
    }

    static func write(_ image: CGImage, format: ImageFormat, quality: Double, directory: String) throws {
        let data: Data?
        switch format {
        case .png:
            data = ImageExporter.pngData(from: image)
        case .jpeg:
            data = ImageExporter.jpegData(from: image, quality: quality)
        }
        guard let data else { throw EditorError.encodeFailed }
        let url = URL(fileURLWithPath: directory)
            .appendingPathComponent(defaultFileName(format: format))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
