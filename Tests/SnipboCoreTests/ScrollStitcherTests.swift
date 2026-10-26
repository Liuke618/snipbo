import CoreGraphics
import Testing
@testable import SnipboCore

@Suite("ScrollStitcherTests")
struct ScrollStitcherTests {
    @Test func testInitialImageIsKeptWhenUnderLimit() throws {
        let image = try makeRows([0, 1, 2, 3])
        let result = try #require(ScrollStitcher.makeInitial(image: image, maxHeight: 10))
        #expect(result.image.height == 4)
        #expect(result.appendedRows == 0)
        #expect(!result.reachedLimit)
    }

    @Test func testInitialImageIsTruncatedAtLimit() throws {
        let image = try makeRows([0, 1, 2, 3, 4])
        let result = try #require(ScrollStitcher.makeInitial(image: image, maxHeight: 3))
        #expect(result.image.height == 3)
        #expect(result.reachedLimit)
    }

    @Test func testAppendSkipsOverlapAndKeepsTopImage() throws {
        let initial = try makeRows([0, 1, 2, 3])
        let frame = try makeRows([4, 5, 6, 7])
        let result = try #require(ScrollStitcher.append(
            composite: initial,
            frame: frame,
            offset: 2,
            maxHeight: 100
        ))
        #expect(result.image.height == 6)
        #expect(result.appendedRows == 2)
        #expect(!result.reachedLimit)
        #expect(try rows(of: result.image) == [0, 1, 2, 3, 6, 7])
    }

    @Test func testAppendStopsAtMaximumHeight() throws {
        let initial = try makeRows([0, 1, 2, 3])
        let frame = try makeRows([4, 5, 6, 7])
        let result = try #require(ScrollStitcher.append(
            composite: initial,
            frame: frame,
            offset: 1,
            maxHeight: 6
        ))
        #expect(result.image.height == 6)
        #expect(result.appendedRows == 2)
        #expect(result.reachedLimit)
        #expect(try rows(of: result.image) == [0, 1, 2, 3, 5, 6])
    }

    @Test func testPrependAddsRowsAboveComposite() throws {
        let composite = try makeRows([2, 3])
        let frame = try makeRows([0, 1, 2, 3])
        let result = try #require(ScrollStitcher.prepend(
            composite: composite,
            frame: frame,
            rows: 2,
            maxHeight: 100
        ))
        #expect(result.image.height == 4)
        #expect(result.appendedRows == 2)
        #expect(!result.reachedLimit)
        #expect(try rows(of: result.image) == [0, 1, 2, 3])
    }

    @Test func testPrependStopsAtMaximumHeightKeepingRowsAdjacentToComposite() throws {
        let composite = try makeRows([2, 3])
        let frame = try makeRows([0, 1, 2, 3])
        let result = try #require(ScrollStitcher.prepend(
            composite: composite,
            frame: frame,
            rows: 2,
            maxHeight: 3
        ))
        #expect(result.image.height == 3)
        #expect(result.appendedRows == 1)
        #expect(result.reachedLimit)
        #expect(try rows(of: result.image) == [1, 2, 3])
    }

    @Test func testInvalidPrependRowsAndWidthsAreIgnored() throws {
        let composite = try makeRows([2, 3])
        let frame = try makeRows([0, 1, 2, 3])
        #expect(ScrollStitcher.prepend(composite: composite, frame: frame, rows: 0, maxHeight: 100) == nil)
        #expect(ScrollStitcher.prepend(composite: composite, frame: frame, rows: 4, maxHeight: 100) == nil)
        let narrow = try makeRows([8, 9], width: 2)
        #expect(ScrollStitcher.prepend(composite: composite, frame: narrow, rows: 1, maxHeight: 100) == nil)
    }

    @Test func testInvalidOffsetsAndWidthsAreIgnored() throws {
        let initial = try makeRows([0, 1, 2, 3])
        let frame = try makeRows([4, 5, 6, 7])
        #expect(ScrollStitcher.append(composite: initial, frame: frame, offset: 0, maxHeight: 100) == nil)
        #expect(ScrollStitcher.append(composite: initial, frame: frame, offset: -1, maxHeight: 100) == nil)
        #expect(ScrollStitcher.append(composite: initial, frame: frame, offset: 4, maxHeight: 100) == nil)
        let narrow = try makeRows([8, 9], width: 2)
        #expect(ScrollStitcher.append(composite: initial, frame: narrow, offset: 1, maxHeight: 100) == nil)
    }
}

@Suite("ScrollAlignmentTests")
struct ScrollAlignmentTests {
    @Test func testFrontierSkipRowsForDownwardScroll() {
        // Frontier-reference registration: the stitched composite's bottom
        // strip is the reference, so scrolling down moves the strip's content
        // UP in the new frame — a POSITIVE ty whose magnitude is the rows of
        // new content at the frame's bottom.
        #expect(ScrollAlignment.frontierSkipRows(translationY: 1, stripHeight: 4, frameHeight: 4) == 3)
        #expect(ScrollAlignment.frontierSkipRows(translationY: 300, stripHeight: 800, frameHeight: 800) == 500)
    }

    @Test func testLeadingRowsForUpwardScroll() {
        // Registration against the top strip: scrolling up yields a negative
        // ty whose magnitude is the new rows at the frame's top.
        #expect(ScrollAlignment.leadingRows(translationY: -1, stripHeight: 4, frameHeight: 4) == 1)
        #expect(ScrollAlignment.leadingRows(translationY: -300, stripHeight: 800, frameHeight: 800) == 300)
        #expect(ScrollAlignment.leadingRows(translationY: 0, stripHeight: 800, frameHeight: 800) == nil)
        #expect(ScrollAlignment.leadingRows(translationY: 1, stripHeight: 800, frameHeight: 800) == nil)
        #expect(ScrollAlignment.leadingRows(translationY: -800, stripHeight: 800, frameHeight: 800) == nil)
    }

    @Test func testFrontierRejectsUpwardNoMovementAndJumps() {
        #expect(ScrollAlignment.frontierSkipRows(translationY: 0, stripHeight: 4, frameHeight: 4) == nil)
        #expect(ScrollAlignment.frontierSkipRows(translationY: -1, stripHeight: 4, frameHeight: 4) == nil)
        #expect(ScrollAlignment.frontierSkipRows(translationY: 4, stripHeight: 4, frameHeight: 4) == nil)
        #expect(ScrollAlignment.frontierSkipRows(translationY: 5, stripHeight: 4, frameHeight: 4) == nil)
    }

    @Test func testStitchedScrollProducesContinuousImage() throws {
        // Review Critical #1 regression: a real scroll of one row. The frame's
        // content is the composite shifted up by one, the frontier translation
        // is +1, and appending must add exactly the single new bottom row.
        let composite = try makeRows([0, 1, 2, 3])
        let frame = try makeRows([1, 2, 3, 4])
        let skip = try #require(ScrollAlignment.frontierSkipRows(translationY: 1, stripHeight: 4, frameHeight: 4))
        let result = try #require(ScrollStitcher.append(
            composite: composite,
            frame: frame,
            offset: skip,
            maxHeight: 100
        ))
        #expect(try rows(of: result.image) == [0, 1, 2, 3, 4])
    }

    @Test func testFrontierStitchLoopSurvivesScrollWiggle() throws {
        // An 8-row document viewed through a 4-row viewport, scrolled down in
        // one-row steps with an up-down wiggle in the middle. The frontier
        // reference must keep the stitched image continuous: every document
        // row exactly once, no duplicates, no gaps. (Adjacent-frame
        // registration duplicated rows 2–4 after the wiggle.)
        let doc = try makeRows(Array(0..<8))
        func frame(top: Int) throws -> CGImage {
            try #require(doc.cropping(to: CGRect(x: 0, y: top, width: 4, height: 4)))
        }
        var composite = try #require(
            ScrollStitcher.makeInitial(image: try frame(top: 0), maxHeight: 100)
        ).image
        for top in [1, 2, 1, 2, 3, 4] {
            let current = composite
            let stripHeight = min(4, current.height)
            let stripTop = current.height - stripHeight
            _ = try #require(current.cropping(to: CGRect(
                x: 0, y: stripTop, width: 4, height: stripHeight
            )))
            // Synthetic registration: scrolling down moves the strip content
            // up, so ty is the frame top minus the strip top.
            let translationY = top - stripTop
            if let skip = ScrollAlignment.frontierSkipRows(
                translationY: translationY,
                stripHeight: stripHeight,
                frameHeight: 4
            ) {
                composite = try #require(ScrollStitcher.append(
                    composite: current,
                    frame: try frame(top: top),
                    offset: skip,
                    maxHeight: 100
                )).image
            }
        }
        #expect(try rows(of: composite) == Array(0..<8))
    }

    @Test func testEffectiveMaxHeightIsAreaCapped() {
        // 40 Mpx budget: a 4000 px wide frame caps at 10000 rows.
        #expect(ScrollAlignment.effectiveMaxHeight(requested: 100_000, width: 4_000) == 10_000)
        // The default 20000 px at 2000 px width stays untouched.
        #expect(ScrollAlignment.effectiveMaxHeight(requested: 20_000, width: 2_000) == 20_000)
        // Narrow captures keep the full requested height.
        #expect(ScrollAlignment.effectiveMaxHeight(requested: 100_000, width: 100) == 100_000)
    }
}

@Suite("ScrollOverlapTests")
struct ScrollOverlapTests {
    @Test func testIdenticalOverlapIsTrusted() throws {
        let doc = try makeChatBlocks()
        let frame = try #require(doc.cropping(to: CGRect(
            x: 0, y: 100, width: doc.width, height: 500
        )))
        // Composite rows 200…600 and frame rows 100…500 are the same content.
        #expect(ScrollOverlap.confidentlyOverlaps(
            composite: doc,
            frame: frame,
            compositeRowOffset: 200,
            frameRowOffset: 100,
            rows: 400
        ))
    }

    @Test func testRepeatedLayoutWithDifferentContentIsRejected() throws {
        let doc = try makeChatBlocks()
        let frame = try #require(doc.cropping(to: CGRect(
            x: 0, y: 100, width: doc.width, height: 500
        )))
        // Offset by exactly one block: layout edges align but the unique
        // markers do not — the false-positive Vision reports on chat layouts.
        #expect(!ScrollOverlap.confidentlyOverlaps(
            composite: doc,
            frame: frame,
            compositeRowOffset: 200,
            frameRowOffset: 20,
            rows: 400
        ))
    }

    @Test func testBlankAndTinyOverlapsAreRejected() throws {
        let doc = try makeChatBlocks()
        let frame = try #require(doc.cropping(to: CGRect(
            x: 0, y: 100, width: doc.width, height: 500
        )))
        #expect(!ScrollOverlap.confidentlyOverlaps(
            composite: doc,
            frame: frame,
            compositeRowOffset: 0,
            frameRowOffset: 0,
            rows: ScrollOverlap.minimumRows - 1
        ))
        // Uniform content has no edges, so an overlap cannot be verified.
        let blank = try makeRows(Array(repeating: 128, count: 200), width: 64)
        #expect(!ScrollOverlap.confidentlyOverlaps(
            composite: blank,
            frame: blank,
            compositeRowOffset: 0,
            frameRowOffset: 0,
            rows: 100
        ))
    }

    @Test func testOutOfBoundsOverlapIsRejected() throws {
        let doc = try makeChatBlocks()
        #expect(!ScrollOverlap.confidentlyOverlaps(
            composite: doc,
            frame: doc,
            compositeRowOffset: doc.height - 100,
            frameRowOffset: 0,
            rows: 200
        ))
        #expect(!ScrollOverlap.confidentlyOverlaps(
            composite: doc,
            frame: doc,
            compositeRowOffset: 0,
            frameRowOffset: -1,
            rows: 200
        ))
    }
}

// sRGB everywhere: a DeviceRGB fill→makeImage→draw round-trip perturbs low
// byte values by ~1 (color matching), which would break exact row assertions.
private let rowColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

private func makeRows(_ values: [UInt8], width: Int = 4) throws -> CGImage {
    let height = values.count
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: rowColorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    for (row, value) in values.enumerated() {
        context.setFillColor(CGColor(
            colorSpace: rowColorSpace,
            components: [CGFloat(value) / 255, 0, 0, 1]
        )!)
        // CGContext is bottom-left oriented; row 0 of the resulting CGImage is
        // the top row, so draw the first value at the top.
        context.fill(CGRect(x: 0, y: height - row - 1, width: width, height: 1))
    }
    return try #require(context.makeImage())
}

/// A chat-like document: repeated layout bands with a unique marker per
/// block, so a whole-block offset keeps layout edges aligned while the marker
/// edges stop matching.
private func makeChatBlocks(
    blocks: Int = 10,
    width: Int = 240,
    blockHeight: Int = 80
) throws -> CGImage {
    let height = blocks * blockHeight
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: rowColorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(colorSpace: rowColorSpace, components: [1, 1, 1, 1])!)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for block in 0..<blocks {
        // CGContext is bottom-left oriented; block 0 is the top block.
        let y = height - (block + 1) * blockHeight
        context.setFillColor(CGColor(
            colorSpace: rowColorSpace,
            components: [0.88, 0.88, 0.88, 1]
        )!)
        context.fill(CGRect(x: 8, y: y + 10, width: width - 16, height: blockHeight - 20))
        let markerX = 16 + (block * 37) % (width - 80)
        context.setFillColor(CGColor(colorSpace: rowColorSpace, components: [0, 0, 0, 1])!)
        context.fill(CGRect(x: markerX, y: y + 30, width: 48, height: 8))
    }
    return try #require(context.makeImage())
}

private func rows(of image: CGImage) throws -> [UInt8] {
    let width = image.width
    let height = image.height
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: rowColorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let data = try #require(context.data)
    let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
    return (0..<height).map { bytes[$0 * width * 4] }
}

@Suite("ScrollCompositeTests")
struct ScrollCompositeTests {
    @Test func testAppendMatchesStitcherRows() throws {
        let composite = try #require(ScrollComposite(image: makeRows([0, 1, 2, 3]), maxHeight: 100))
        #expect(composite.append(frame: try makeRows([4, 5, 6, 7]), offset: 2))
        #expect(composite.height == 6)
        #expect(composite.appendedRows == 2)
        #expect(!composite.reachedLimit)
        let image = try #require(composite.makeImage())
        #expect(try rows(of: image) == [0, 1, 2, 3, 6, 7])
    }

    @Test func testAppendStopsAtMaximumHeight() throws {
        let composite = try #require(ScrollComposite(image: makeRows([0, 1, 2, 3]), maxHeight: 6))
        #expect(composite.append(frame: try makeRows([4, 5, 6, 7]), offset: 1))
        #expect(composite.height == 6)
        #expect(composite.appendedRows == 2)
        #expect(composite.reachedLimit)
        let image = try #require(composite.makeImage())
        #expect(try rows(of: image) == [0, 1, 2, 3, 5, 6])
    }

    @Test func testPrependAddsRowsAboveComposite() throws {
        let composite = try #require(ScrollComposite(image: makeRows([2, 3]), maxHeight: 100))
        #expect(composite.prepend(frame: try makeRows([0, 1, 2, 3]), rows: 2))
        #expect(composite.height == 4)
        #expect(composite.appendedRows == 2)
        #expect(!composite.reachedLimit)
        let image = try #require(composite.makeImage())
        #expect(try rows(of: image) == [0, 1, 2, 3])
    }

    @Test func testPrependStopsAtMaximumHeightKeepingRowsAdjacentToComposite() throws {
        let composite = try #require(ScrollComposite(image: makeRows([2, 3]), maxHeight: 3))
        #expect(composite.prepend(frame: try makeRows([0, 1, 2, 3]), rows: 2))
        #expect(composite.height == 3)
        #expect(composite.appendedRows == 1)
        #expect(composite.reachedLimit)
        let image = try #require(composite.makeImage())
        #expect(try rows(of: image) == [1, 2, 3])
    }

    @Test func testTopAndBottomStripsSpanPrependAndMainContent() throws {
        let composite = try #require(ScrollComposite(image: makeRows([2, 3]), maxHeight: 100))
        #expect(composite.prepend(frame: try makeRows([0, 1, 2, 3]), rows: 2))

        let topTwo = try #require(composite.topStrip(rows: 2))
        #expect(try rows(of: topTwo) == [0, 1])
        let bottomTwo = try #require(composite.bottomStrip(rows: 2))
        #expect(try rows(of: bottomTwo) == [2, 3])
        let topThree = try #require(composite.topStrip(rows: 3))
        #expect(try rows(of: topThree) == [0, 1, 2])
        let bottomThree = try #require(composite.bottomStrip(rows: 3))
        #expect(try rows(of: bottomThree) == [1, 2, 3])
    }

    @Test func testInvalidOperationsAreRejected() throws {
        let composite = try #require(ScrollComposite(image: makeRows([0, 1, 2, 3]), maxHeight: 100))
        let narrow = try makeRows([8, 9], width: 2)
        #expect(!composite.append(frame: try makeRows([4, 5, 6, 7]), offset: 0))
        #expect(!composite.append(frame: try makeRows([4, 5, 6, 7]), offset: -1))
        #expect(!composite.append(frame: try makeRows([4, 5, 6, 7]), offset: 4))
        #expect(!composite.append(frame: narrow, offset: 1))
        #expect(!composite.prepend(frame: try makeRows([0, 1, 2, 3]), rows: 0))
        #expect(!composite.prepend(frame: try makeRows([0, 1, 2, 3]), rows: 4))
        #expect(!composite.prepend(frame: narrow, rows: 1))
        #expect(composite.topStrip(rows: 0) == nil)
        #expect(composite.bottomStrip(rows: 0) == nil)
        #expect(composite.height == 4)
    }
}
