import Foundation

public enum CaptureSource: String, Codable, Sendable {
    case region
    case window
    case fullScreen
    case scrolling
    /// A recovered entry whose original capture mode is no longer known.
    case unknown
}

public struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let source: CaptureSource
    public let imageFileName: String
    public let thumbnailFileName: String

    public init(
        id: UUID,
        createdAt: Date,
        pixelWidth: Int,
        pixelHeight: Int,
        source: CaptureSource,
        imageFileName: String,
        thumbnailFileName: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.source = source
        self.imageFileName = imageFileName
        self.thumbnailFileName = thumbnailFileName
    }
}
