import CoreGraphics

public struct EditDocument: @unchecked Sendable {
    public let image: CGImage
    public var cropRect: CGRect
    public var annotations: [Annotation]
    /// Physical pixels per point of the display the capture came from (2 on
    /// Retina). Lets the editor show sizes in logical points; file-loaded
    /// images use 1.
    public let backingScale: CGFloat

    public init(image: CGImage, backingScale: CGFloat = 1) {
        self.image = image
        self.cropRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        self.annotations = []
        self.backingScale = max(1, backingScale)
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
