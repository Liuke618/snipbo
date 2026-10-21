import CoreGraphics

public struct EditDocument: @unchecked Sendable {
    public let image: CGImage
    public var cropRect: CGRect
    public var annotations: [Annotation]

    public init(image: CGImage) {
        self.image = image
        self.cropRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        self.annotations = []
    }

    public var imagePixelSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }

    public var state: DocumentState {
        DocumentState(cropRect: cropRect, annotations: annotations)
    }

    public mutating func apply(_ state: DocumentState) {
        cropRect = state.cropRect
        annotations = state.annotations
    }
}

public struct DocumentState: Equatable, Sendable {
    public var cropRect: CGRect
    public var annotations: [Annotation]

    public init(cropRect: CGRect, annotations: [Annotation]) {
        self.cropRect = cropRect
        self.annotations = annotations
    }
}
