import CoreGraphics
import Foundation
import Testing
@testable import SnipboCore

@Suite("TextLayoutTests")
struct TextLayoutTests {
    @Test func testMultilineTextGrowsBeyondOneLine() {
        let style = AnnotationStyle(fontSize: 20)
        let value = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 4)
        let size = TextLayout.size(value: value, width: 160, style: style)
        #expect(size.width == 160)
        #expect(size.height > style.fontSize * 1.4 * 2)
    }

    @Test func testAnnotationBoundsUseLayout() {
        let style = AnnotationStyle(fontSize: 20)
        let value = String(repeating: "wrap ", count: 30)
        let annotation = Annotation(
            kind: .text,
            geometry: .text(origin: CGPoint(x: 10, y: 20), width: 120, value: value),
            style: style,
            zIndex: 1
        )
        let expected = TextLayout.size(value: value, width: 120, style: style)
        #expect(annotation.bounds.origin == CGPoint(x: 10, y: 20))
        #expect(annotation.bounds.size == expected)
    }

    @Test func testHitTestingCoversWrappedLines() {
        let style = AnnotationStyle(fontSize: 20)
        let value = String(repeating: "wrap ", count: 40)
        let annotation = Annotation(
            kind: .text,
            geometry: .text(origin: .zero, width: 100, value: value),
            style: style,
            zIndex: 1
        )
        #expect(annotation.bounds.height > style.fontSize * 1.4 * 2)
        let lastLinePoint = CGPoint(
            x: annotation.bounds.midX,
            y: annotation.bounds.maxY - 2
        )
        #expect(AnnotationHitTester.topmost(
            in: [annotation],
            at: lastLinePoint,
            tolerance: 2
        ) != nil)
    }

    @Test func testLegacyStyleDecodesWithoutTextFields() throws {
        let json = """
        {
          "color": {"red": 1, "green": 0, "blue": 0, "alpha": 1},
          "lineWidth": 3,
          "opacity": 1,
          "fontSize": 24,
          "pixelBlockSize": 12
        }
        """
        let style = try JSONDecoder().decode(
            AnnotationStyle.self,
            from: Data(json.utf8)
        )
        #expect(style.fontName == nil)
        #expect(style.fontBold == nil)
        #expect(style.textAlignment == nil)
        #expect(style.textBackground == nil)
        #expect(style.textOutline == nil)
        #expect(style.lineStyle == nil)
        #expect(style.arrowStyle == nil)
        #expect(style.fillColor == nil)
    }

    @Test func testTextStyleRoundTrip() throws {
        let style = AnnotationStyle(
            fontSize: 36,
            fontName: "Menlo-Regular",
            fontBold: true,
            textAlignment: .center,
            textBackground: RGBA(red: 0, green: 0, blue: 0, alpha: 0.5),
            textOutline: .black,
            lineStyle: .dashed,
            arrowStyle: .simple,
            fillColor: RGBA(red: 0, green: 0, blue: 1, alpha: 0.25)
        )
        let data = try JSONEncoder().encode(style)
        let decoded = try JSONDecoder().decode(AnnotationStyle.self, from: data)
        #expect(decoded == style)
    }
}
