import CoreGraphics
import Testing
@testable import LightShotCore

@Suite("AnnotationTests")
struct AnnotationTests {
    @Test func testHitTesterPrefersTopmostAnnotation() {
        let lower = Annotation(
            kind: .rectangle,
            geometry: .rect(CGRect(x: 0, y: 0, width: 50, height: 50)),
            style: AnnotationStyle(),
            zIndex: 1
        )
        let upper = Annotation(
            kind: .ellipse,
            geometry: .rect(CGRect(x: 10, y: 10, width: 20, height: 20)),
            style: AnnotationStyle(),
            zIndex: 2
        )
        let hit = AnnotationHitTester.topmost(
            in: [lower, upper],
            at: CGPoint(x: 15, y: 15),
            tolerance: 2
        )
        #expect(hit?.id == upper.id)
    }

    @Test func testLineHitTestingUsesDistance() {
        let line = Annotation(
            kind: .line,
            geometry: .line(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 100)),
            style: AnnotationStyle(lineWidth: 4),
            zIndex: 1
        )
        #expect(AnnotationHitTester.topmost(in: [line], at: CGPoint(x: 50, y: 52), tolerance: 4) != nil)
        #expect(AnnotationHitTester.topmost(in: [line], at: CGPoint(x: 50, y: 70), tolerance: 4) == nil)
    }

    @Test func testFreehandPathHitTesting() {
        let path = Annotation(
            kind: .freehand,
            geometry: .path(points: [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 20), CGPoint(x: 40, y: 0)]),
            style: AnnotationStyle(lineWidth: 3),
            zIndex: 1
        )
        #expect(AnnotationHitTester.topmost(in: [path], at: CGPoint(x: 21, y: 19), tolerance: 4) != nil)
        #expect(AnnotationHitTester.topmost(in: [path], at: CGPoint(x: 100, y: 100), tolerance: 4) == nil)
    }
}
