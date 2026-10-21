import Foundation

public enum ImageFormat: String, Codable, Sendable {
    case png
    case jpeg
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var hotkey: Hotkey
    public var saveDirectory: String
    public var format: ImageFormat
    public var jpegQuality: Double
    public var openEditorAfterCapture: Bool
    public var historyEnabled: Bool
    public var historyMaxItems: Int
    public var historyMaxBytes: Int64
    public var captureCursor: Bool

    public init(
        hotkey: Hotkey,
        saveDirectory: String,
        format: ImageFormat,
        jpegQuality: Double,
        openEditorAfterCapture: Bool,
        historyEnabled: Bool,
        historyMaxItems: Int,
        historyMaxBytes: Int64,
        captureCursor: Bool
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
        captureCursor: false
    )

    public func normalized() -> AppSettings {
        var copy = self
        copy.jpegQuality = min(1, max(0.1, jpegQuality))
        copy.historyMaxItems = min(1000, max(1, historyMaxItems))
        copy.historyMaxBytes = min(10 * 1024 * 1024 * 1024, max(10 * 1024 * 1024, historyMaxBytes))
        if copy.saveDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.saveDirectory = Self.defaultSaveDirectory
        }
        return copy
    }
}
