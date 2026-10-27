import CoreGraphics
import Foundation
import SnipboCore

/// Writes captures into the save directory. Shared by the editor's save and
/// the direct auto-save path so file naming cannot drift.
enum CaptureFileSaver {
    /// Serializes the name check + write so two captures finishing in the same
    /// second cannot both pick the same file name.
    private static let writeLock = NSLock()
    /// Guarded by `writeLock`; the annotation records that the lock, not the
    /// type system, provides the synchronization.
    nonisolated(unsafe) private static var sequence = 0

    static func defaultFileName(
        format: ImageFormat,
        template: String = "Snipbo-{datetime}",
        metadata: CaptureMetadata? = nil
    ) -> String {
        makeName(
            fileExtension: format.fileExtension,
            template: template,
            metadata: metadata
        )
    }

    static func defaultRecordingFileName(
        format: RecordingFormat,
        template: String = "Snipbo-{datetime}",
        metadata: CaptureMetadata? = nil
    ) -> String {
        makeName(
            fileExtension: format.fileExtension,
            template: template,
            metadata: metadata
        )
    }

    private static func makeName(
        fileExtension: String,
        template: String,
        metadata: CaptureMetadata?
    ) -> String {
        let now = Date()
        let date = formatted(now, "yyyy-MM-dd")
        let time = formatted(now, "HHmmss")
        let datetime = formatted(now, "yyyy-MM-dd-HHmmss")

        writeLock.lock()
        sequence += 1
        let sequenceValue = sequence
        writeLock.unlock()

        var name = template
        name = name.replacingOccurrences(of: "{datetime}", with: datetime)
        name = name.replacingOccurrences(of: "{date}", with: date)
        name = name.replacingOccurrences(of: "{time}", with: time)
        name = name.replacingOccurrences(of: "{source}", with: sourceToken(metadata?.source))
        name = name.replacingOccurrences(of: "{app}", with: metadata?.appName ?? "")
        name = name.replacingOccurrences(of: "{window}", with: metadata?.windowTitle ?? "")
        name = name.replacingOccurrences(of: "{n}", with: "\(sequenceValue)")

        name = strippingKnownExtension(name)
        name = sanitize(name)
        if name.isEmpty {
            name = "Snipbo-\(datetime)"
        }
        return "\(name).\(fileExtension)"
    }

    static func write(
        _ image: CGImage,
        format: ImageFormat,
        quality: Double,
        directory: String,
        targetBytes: Int? = nil,
        template: String = "Snipbo-{datetime}",
        metadata: CaptureMetadata? = nil
    ) throws {
        try write(
            image,
            format: format,
            quality: quality,
            targetBytes: targetBytes,
            directory: URL(fileURLWithPath: directory),
            preferredName: defaultFileName(
                format: format,
                template: template,
                metadata: metadata
            ),
            uniqueName: true
        )
    }

    /// Writes to an explicit URL chosen by the user; an existing file is
    /// replaced after the save panel's own overwrite confirmation.
    static func write(
        _ image: CGImage,
        to url: URL,
        format: ImageFormat,
        quality: Double,
        targetBytes: Int? = nil
    ) throws {
        try write(
            image,
            format: format,
            quality: quality,
            targetBytes: targetBytes,
            directory: url.deletingLastPathComponent(),
            preferredName: url.lastPathComponent,
            uniqueName: false
        )
    }

    private static func write(
        _ image: CGImage,
        format: ImageFormat,
        quality: Double,
        targetBytes: Int?,
        directory: URL,
        preferredName: String,
        uniqueName: Bool
    ) throws {
        let data = try encodedData(
            image,
            format: format,
            quality: quality,
            targetBytes: targetBytes
        )
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
        quality: Double,
        targetBytes: Int?
    ) throws -> Data {
        guard let data = ImageExporter.data(
            from: image,
            format: format,
            quality: quality,
            targetBytes: targetBytes
        ) else {
            throw EditorError.encodeFailed
        }
        return data
    }

    private static func formatted(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private static func sourceToken(_ source: CaptureSource?) -> String {
        switch source {
        case .region: return "region"
        case .window: return "window"
        case .fullScreen: return "screen"
        case .scrolling: return "scroll"
        case .unknown, .none: return "capture"
        }
    }

    private static func strippingKnownExtension(_ name: String) -> String {
        let extensions = ["png", "jpg", "jpeg", "heic", "avif"]
        for ext in extensions where name.lowercased().hasSuffix(".\(ext)") {
            return String(name.dropLast(ext.count + 1))
        }
        return name
    }

    /// Keeps the name safe on case-insensitive and Finder-hostile paths.
    private static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\*?\"<>|")
        var cleaned = name
            .components(separatedBy: invalid)
            .joined(separator: "-")
        cleaned = cleaned.replacingOccurrences(
            of: "-{2,}",
            with: "-",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: " {2,}",
            with: " ",
            options: .regularExpression
        )
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " .-_"))
        return String(cleaned.prefix(120))
    }
}
