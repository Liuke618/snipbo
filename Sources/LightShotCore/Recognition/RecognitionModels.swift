import CoreGraphics

public struct TextBlock: Equatable, Sendable {
    public let text: String
    /// Vision-normalized box with a bottom-left origin.
    public let boundingBox: CGRect
    public let confidence: Float

    public init(text: String, boundingBox: CGRect, confidence: Float) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }

    /// Converts the Vision box to a top-left pixel rect in the image that was
    /// passed to Vision.
    public func pixelRect(imageWidth: Int, imageHeight: Int) -> CGRect {
        guard imageWidth > 0, imageHeight > 0 else { return .zero }
        let width = CGFloat(imageWidth)
        let height = CGFloat(imageHeight)
        return CGRect(
            x: boundingBox.minX * width,
            y: (1 - boundingBox.maxY) * height,
            width: boundingBox.width * width,
            height: boundingBox.height * height
        )
    }
}

public struct BarcodeResult: Equatable, Sendable {
    public let payload: String
    public let symbology: String
    /// Vision-normalized box with a bottom-left origin.
    public let boundingBox: CGRect

    public init(payload: String, symbology: String, boundingBox: CGRect) {
        self.payload = payload
        self.symbology = symbology
        self.boundingBox = boundingBox
    }

    public func pixelRect(imageWidth: Int, imageHeight: Int) -> CGRect {
        guard imageWidth > 0, imageHeight > 0 else { return .zero }
        let width = CGFloat(imageWidth)
        let height = CGFloat(imageHeight)
        return CGRect(
            x: boundingBox.minX * width,
            y: (1 - boundingBox.maxY) * height,
            width: boundingBox.width * width,
            height: boundingBox.height * height
        )
    }
}

public struct RecognitionResult: Equatable, Sendable {
    public let textBlocks: [TextBlock]
    public let barcodes: [BarcodeResult]

    public init(textBlocks: [TextBlock], barcodes: [BarcodeResult]) {
        self.textBlocks = textBlocks.sorted {
            Self.isOrderedBefore($0.boundingBox, $1.boundingBox)
        }
        self.barcodes = barcodes.sorted {
            Self.isOrderedBefore($0.boundingBox, $1.boundingBox)
        }
    }

    public var isEmpty: Bool { textBlocks.isEmpty && barcodes.isEmpty }

    public var combinedText: String {
        textBlocks.map(\.text).joined(separator: "\n")
    }

    /// Text for the copy-all action, including barcode payloads.
    public var plainText: String {
        var sections: [String] = []
        if !textBlocks.isEmpty {
            sections.append(combinedText)
        }
        if !barcodes.isEmpty {
            let lines = barcodes.map { "\($0.payload) (\($0.symbology))" }
            sections.append("Barcodes:\n" + lines.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    /// Top-to-bottom, then left-to-right, using Vision's bottom-left boxes.
    private static func isOrderedBefore(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        if lhs.maxY != rhs.maxY {
            return lhs.maxY > rhs.maxY
        }
        return lhs.minX < rhs.minX
    }
}
