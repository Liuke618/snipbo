import CoreGraphics
import Testing
@testable import LightShotCore

@Suite("EditDocumentTests")
struct EditDocumentTests {
    /// Builds a 4x3 RGB bitmap context purely as a source image for the document.
    private func makeImage() throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil,
                width: 4,
                height: 3,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        return try #require(context.makeImage())
    }

    @Test func testInitialCropRectMatchesFullImage() throws {
        let document = EditDocument(image: try makeImage())

        #expect(document.cropRect == CGRect(x: 0, y: 0, width: 4, height: 3))
        #expect(document.annotations.isEmpty)
    }

    @Test func testImagePixelSizeMatchesBitmapDimensions() throws {
        let document = EditDocument(image: try makeImage())

        #expect(document.imagePixelSize == CGSize(width: 4, height: 3))
    }

    @Test func testStateReflectsMutatedCropRectAndAnnotations() throws {
        var document = EditDocument(image: try makeImage())
        let annotation = Annotation(
            kind: .rectangle,
            geometry: .rect(CGRect(x: 1, y: 1, width: 2, height: 1)),
            style: AnnotationStyle(),
            zIndex: 1
        )
        let cropRect = CGRect(x: 1, y: 1, width: 2, height: 2)

        document.cropRect = cropRect
        document.annotations = [annotation]

        #expect(document.state.cropRect == cropRect)
        #expect(document.state.annotations == [annotation])
    }

    @Test func testApplyRestoresCropRectAndAnnotations() throws {
        var document = EditDocument(image: try makeImage())
        let annotation = Annotation(
            kind: .ellipse,
            geometry: .rect(CGRect(x: 0, y: 0, width: 3, height: 2)),
            style: AnnotationStyle(lineWidth: 2),
            zIndex: 1
        )
        let target = DocumentState(
            cropRect: CGRect(x: 0, y: 0, width: 3, height: 2),
            annotations: [annotation]
        )

        document.cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        document.annotations = []
        document.apply(target)

        #expect(document.cropRect == target.cropRect)
        #expect(document.annotations == target.annotations)
        #expect(document.state == target)
    }
}
