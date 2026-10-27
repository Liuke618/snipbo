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
    /// Locally recognized text used by the history search. nil means the
    /// entry has not been indexed (old entries or indexing disabled).
    public var ocrText: String?
    public var tags: [String]
    public var isFavorite: Bool

    public init(
        id: UUID,
        createdAt: Date,
        pixelWidth: Int,
        pixelHeight: Int,
        source: CaptureSource,
        imageFileName: String,
        thumbnailFileName: String,
        ocrText: String? = nil,
        tags: [String] = [],
        isFavorite: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.source = source
        self.imageFileName = imageFileName
        self.thumbnailFileName = thumbnailFileName
        self.ocrText = ocrText
        self.tags = tags
        self.isFavorite = isFavorite
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case pixelWidth
        case pixelHeight
        case source
        case imageFileName
        case thumbnailFileName
        case ocrText
        case tags
        case isFavorite
    }

    /// Older indexes predate search and tags; missing fields keep their
    /// defaults instead of failing the whole history load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        pixelWidth = try container.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decode(Int.self, forKey: .pixelHeight)
        source = try container.decode(CaptureSource.self, forKey: .source)
        imageFileName = try container.decode(String.self, forKey: .imageFileName)
        thumbnailFileName = try container.decode(String.self, forKey: .thumbnailFileName)
        ocrText = try container.decodeIfPresent(String.self, forKey: .ocrText)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(pixelWidth, forKey: .pixelWidth)
        try container.encode(pixelHeight, forKey: .pixelHeight)
        try container.encode(source, forKey: .source)
        try container.encode(imageFileName, forKey: .imageFileName)
        try container.encode(thumbnailFileName, forKey: .thumbnailFileName)
        try container.encodeIfPresent(ocrText, forKey: .ocrText)
        try container.encode(tags, forKey: .tags)
        try container.encode(isFavorite, forKey: .isFavorite)
    }
}
