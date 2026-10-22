import CoreGraphics
import Testing
@testable import LightShotCore

@Suite("DisplayLayoutTests")
struct DisplayLayoutTests {
    private let primary = DisplayLayout.Screen(
        displayID: 1,
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        backingScale: 2
    )
    private let left = DisplayLayout.Screen(
        displayID: 2,
        frame: CGRect(x: -1280, y: 0, width: 1280, height: 800),
        backingScale: 1
    )
    private let above = DisplayLayout.Screen(
        displayID: 3,
        frame: CGRect(x: 0, y: 900, width: 1440, height: 600),
        backingScale: 2
    )

    private var layout: DisplayLayout {
        DisplayLayout(screens: [primary, left, above], primaryHeight: 900)
    }

    @Test func testPrimaryRectIsUnchanged() {
        let rect = CGRect(x: 100, y: 50, width: 300, height: 200)
        #expect(layout.localRect(fromCGRect: rect, on: primary) == rect)
    }

    @Test func testLeftScreenTopStartsAtLocalZero() {
        // The left display's AppKit top is at y=800, which is CG-global y=100.
        let rect = CGRect(x: -1280, y: 100, width: 100, height: 50)
        #expect(
            layout.localRect(fromCGRect: rect, on: left)
                == CGRect(x: 0, y: 0, width: 100, height: 50)
        )
    }

    @Test func testScreenAbovePrimaryTopStartsAtLocalZero() {
        // The display above the primary starts at CG-global y=-600.
        let rect = CGRect(x: 0, y: -600, width: 100, height: 50)
        #expect(
            layout.localRect(fromCGRect: rect, on: above)
                == CGRect(x: 0, y: 0, width: 100, height: 50)
        )
    }

    @Test func testLocalToCGRoundTripOnEveryScreen() {
        let rects: [(DisplayLayout.Screen, CGRect)] = [
            (primary, CGRect(x: 10, y: 20, width: 30, height: 40)),
            (left, CGRect(x: 100, y: 200, width: 50, height: 60)),
            (above, CGRect(x: 300, y: 0, width: 70, height: 80)),
        ]
        for (screen, local) in rects {
            let global = layout.cgRect(fromLocalRect: local, on: screen)
            #expect(layout.localRect(fromCGRect: global, on: screen) == local)
        }
    }

    @Test func testScreenContainingAppKitPoint() {
        // AppKit y=950 is inside the display above the primary.
        #expect(
            layout.screen(containingAppKitPoint: CGPoint(x: 100, y: 950))?.displayID == 3
        )
        // AppKit x=-100, y=100 is inside the left display.
        #expect(
            layout.screen(containingAppKitPoint: CGPoint(x: -100, y: 100))?.displayID == 2
        )
    }

    @Test func testScreenContainingCGPoint() {
        // CG-global y=200 on the left display is 100 points below its top.
        #expect(
            layout.screen(containingCGPoint: CGPoint(x: -100, y: 200))?.displayID == 2
        )
    }

    @Test func testAppKitOriginIsOnThePrimaryScreen() {
        // AppKit (0, 0) is the primary display's bottom-left corner. It converts
        // to local y == height, which must be treated as inside.
        #expect(
            layout.screen(containingAppKitPoint: .zero)?.displayID == 1
        )
    }

    @Test func testPointOnOuterRightEdgeIsOnThePrimaryScreen() {
        // AppKit x=1440 is the primary display's right edge. It converts to
        // local x == width, which must be treated as inside.
        #expect(
            layout.screen(containingAppKitPoint: CGPoint(x: 1440, y: 450))?.displayID == 1
        )
    }

    @Test func testPointOnOuterBottomCGEdgeIsOnThePrimaryScreen() {
        // CG-global y=900 is the primary display's bottom edge.
        #expect(
            layout.screen(containingCGPoint: CGPoint(x: 720, y: 900))?.displayID == 1
        )
    }

    @Test func testPointsJustOutsideTheEdgesAreNotContained() {
        // The inclusive max edge must not leak past the display boundary.
        #expect(layout.screen(containingAppKitPoint: CGPoint(x: 1440.5, y: 450)) == nil)
        #expect(layout.screen(containingAppKitPoint: CGPoint(x: 720, y: -0.5)) == nil)
    }

    @Test func testScreensIntersectingAWindowFrame() {
        // The boundary between the primary and the screen above is CG y=0.
        let spanning = CGRect(x: 100, y: -20, width: 200, height: 100)
        #expect(
            layout.screens(intersectingCGRect: spanning).map(\.displayID) == [1, 3]
        )
    }

    @Test func testBestScreenUsesLargestIntersection() {
        // Entirely inside the primary display.
        #expect(
            layout.bestScreen(forCGRect: CGRect(x: 0, y: 0, width: 100, height: 100))?.displayID == 1
        )
        // Entirely inside the screen above the primary.
        #expect(
            layout.bestScreen(forCGRect: CGRect(x: 0, y: -100, width: 100, height: 100))?.displayID == 3
        )
    }
}
