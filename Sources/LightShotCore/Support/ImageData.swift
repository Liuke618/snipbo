import CoreGraphics

public struct ImageData: @unchecked Sendable {
    public let cgImage: CGImage

    public init(_ cgImage: CGImage) {
        self.cgImage = cgImage
    }
}
