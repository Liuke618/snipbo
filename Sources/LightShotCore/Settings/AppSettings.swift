import Foundation

public enum ImageFormat: String, Codable, Sendable {
    case png
    case jpeg
}

public struct AppSettings: Codable, Equatable, Sendable {
    /// Languages offered in Settings and passed to Vision. Vision identifies
    /// these with BCP-47-style identifiers.
    public static let supportedOCRLanguages = ["zh-Hans", "en-US"]
    public static let defaultOCRLanguages = ["zh-Hans", "en-US"]

    public var hotkey: Hotkey
    public var saveDirectory: String
    public var format: ImageFormat
    public var jpegQuality: Double
    public var openEditorAfterCapture: Bool
    public var historyEnabled: Bool
    public var historyMaxItems: Int
    public var historyMaxBytes: Int64
    public var captureCursor: Bool
    /// Countdown used by the timed capture menu entries, in seconds.
    public var captureDelaySeconds: Int
    /// Ordered languages for `VNRecognizeTextRequest`.
    public var ocrLanguages: [String]

    private enum CodingKeys: String, CodingKey {
        case hotkey
        case saveDirectory
        case format
        case jpegQuality
        case openEditorAfterCapture
        case historyEnabled
        case historyMaxItems
        case historyMaxBytes
        case captureCursor
        case captureDelaySeconds
        case ocrLanguages
    }

    public init(
        hotkey: Hotkey,
        saveDirectory: String,
        format: ImageFormat,
        jpegQuality: Double,
        openEditorAfterCapture: Bool,
        historyEnabled: Bool,
        historyMaxItems: Int,
        historyMaxBytes: Int64,
        captureCursor: Bool,
        captureDelaySeconds: Int = 3,
        ocrLanguages: [String] = AppSettings.defaultOCRLanguages
    ) {
        self.hotkey = hotkey
        self.saveDirectory = saveDirectory
        self.format = format
        self.jpegQuality = jpegQuality
        self.openEditorAfterCapture = openEditorAfterCapture
        self.historyEnabled = historyEnabled
        self.historyMaxItems = historyMaxItems
        self.historyMaxBytes = historyMaxBytes
        self.captureCursor = captureCursor
        self.captureDelaySeconds = captureDelaySeconds
        self.ocrLanguages = ocrLanguages
    }

    /// Decodes every field defensively so payloads written by Phase 1 keep
    /// working after new fields are introduced.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings.default
        hotkey = try container.decodeIfPresent(Hotkey.self, forKey: .hotkey) ?? fallback.hotkey
        saveDirectory = try container.decodeIfPresent(String.self, forKey: .saveDirectory) ?? fallback.saveDirectory
        format = try container.decodeIfPresent(ImageFormat.self, forKey: .format) ?? fallback.format
        jpegQuality = try container.decodeIfPresent(Double.self, forKey: .jpegQuality) ?? fallback.jpegQuality
        openEditorAfterCapture = try container.decodeIfPresent(Bool.self, forKey: .openEditorAfterCapture) ?? fallback.openEditorAfterCapture
        historyEnabled = try container.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? fallback.historyEnabled
        historyMaxItems = try container.decodeIfPresent(Int.self, forKey: .historyMaxItems) ?? fallback.historyMaxItems
        historyMaxBytes = try container.decodeIfPresent(Int64.self, forKey: .historyMaxBytes) ?? fallback.historyMaxBytes
        captureCursor = try container.decodeIfPresent(Bool.self, forKey: .captureCursor) ?? fallback.captureCursor
        captureDelaySeconds = try container.decodeIfPresent(Int.self, forKey: .captureDelaySeconds) ?? fallback.captureDelaySeconds
        ocrLanguages = try container.decodeIfPresent([String].self, forKey: .ocrLanguages) ?? fallback.ocrLanguages
    }

    public static let defaultSaveDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures/LightShot", isDirectory: true)
        .path

    public static let `default` = AppSettings(
        hotkey: Hotkey(keyCode: 26, modifiers: [.command, .shift]),
        saveDirectory: defaultSaveDirectory,
        format: .png,
        jpegQuality: 0.9,
        openEditorAfterCapture: true,
        historyEnabled: true,
        historyMaxItems: 200,
        historyMaxBytes: 500 * 1024 * 1024,
        captureCursor: false,
        captureDelaySeconds: 3,
        ocrLanguages: AppSettings.defaultOCRLanguages
    )

    public func normalized() -> AppSettings {
        var copy = self
        copy.jpegQuality = min(1, max(0.1, jpegQuality))
        copy.historyMaxItems = min(1000, max(1, historyMaxItems))
        copy.historyMaxBytes = min(10 * 1024 * 1024 * 1024, max(10 * 1024 * 1024, historyMaxBytes))
        copy.captureDelaySeconds = min(30, max(0, captureDelaySeconds))
        if copy.saveDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.saveDirectory = Self.defaultSaveDirectory
        }
        var seen = Set<String>()
        copy.ocrLanguages = ocrLanguages.filter {
            Self.supportedOCRLanguages.contains($0) && seen.insert($0).inserted
        }
        if copy.ocrLanguages.isEmpty {
            copy.ocrLanguages = Self.defaultOCRLanguages
        }
        return copy
    }
}
