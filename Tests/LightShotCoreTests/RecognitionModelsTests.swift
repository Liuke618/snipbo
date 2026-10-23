import CoreGraphics
import Testing
@testable import LightShotCore

@Suite("RecognitionModelsTests")
struct RecognitionModelsTests {
    @Test func testPixelRectConvertsVisionBottomLeftToTopLeftPixels() {
        let block = TextBlock(
            text: "Hello",
            boundingBox: CGRect(x: 0, y: 0.8, width: 0.5, height: 0.1),
            confidence: 0.9
        )
        let rect = block.pixelRect(imageWidth: 1000, imageHeight: 1000)
        #expect(abs(rect.minX) < 0.001)
        #expect(abs(rect.minY - 100) < 0.001)
        #expect(abs(rect.width - 500) < 0.001)
        #expect(abs(rect.height - 100) < 0.001)
    }

    @Test func testReadingOrderSortsTopToBottomThenLeftToRight() {
        let top = TextBlock(
            text: "top",
            boundingBox: CGRect(x: 0.5, y: 0.9, width: 0.2, height: 0.05),
            confidence: 1
        )
        let right = TextBlock(
            text: "right",
            boundingBox: CGRect(x: 0.5, y: 0.7, width: 0.2, height: 0.05),
            confidence: 1
        )
        let left = TextBlock(
            text: "left",
            boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.05),
            confidence: 1
        )
        let result = RecognitionResult(textBlocks: [left, top, right], barcodes: [])
        #expect(result.textBlocks.map(\.text) == ["top", "left", "right"])
    }

    @Test func testCombinedAndPlainTextIncludeBarcodePayloads() {
        let block = TextBlock(
            text: "Hello",
            boundingBox: CGRect(x: 0, y: 0.8, width: 0.5, height: 0.1),
            confidence: 1
        )
        let barcode = BarcodeResult(
            payload: "https://example.com",
            symbology: "VNBarcodeSymbologyQR",
            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        )
        let result = RecognitionResult(textBlocks: [block], barcodes: [barcode])
        #expect(result.combinedText == "Hello")
        #expect(result.plainText.contains("Hello"))
        #expect(result.plainText.contains("https://example.com"))
        #expect(result.plainText.contains("VNBarcodeSymbologyQR"))
    }

    @Test func testEmptyResult() {
        let result = RecognitionResult(textBlocks: [], barcodes: [])
        #expect(result.isEmpty)
        #expect(result.plainText.isEmpty)
    }
}
