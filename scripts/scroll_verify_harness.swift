import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import SnipboCore
import Vision
import UniformTypeIdentifiers

/// Phase 3A scrolling-capture verification harness.
///
/// Screen Recording TCC cannot be granted to an unattended CLI process, so
/// SCStream itself is not exercised here. Everything downstream of the stream
/// runs for real: synthetic viewport frames of a numbered ruler document are
/// rendered with CoreGraphics and fed through `ScrollFrameProcessor` — the
/// exact production class, including the real Vision
/// `VNTranslationalImageRegistrationRequest` calls — and the stitched image
/// is then verified pixel-exactly: every 40 pt band of the document has a
/// unique red-channel identity, so any duplicated, missing, or out-of-order
/// band in the stitched output is caught.
///
/// Scenarios: monotonic scroll with an up/down wiggle, a capture started
/// mid-document that scrolls up and then down, no movement, height limit, and
/// an upward scroll back to the start that must add nothing.
///
/// Run with `scripts/run_scroll_verify_harness.sh`. The stitched image is
/// written to /tmp/snipbo-scroll-verify.png for eyeballing.
@main
struct ScrollVerifyHarness {
    static func main() async {
        _ = NSApplication.shared
        let reporter = Reporter()

        do {
            try await scenarioMainScroll(reporter: reporter)
            try await scenarioUpThenDown(reporter: reporter)
            try await scenarioNoMovement(reporter: reporter)
            try await scenarioHeightLimit(reporter: reporter)
            try await scenarioUpwardScrollAppendsNothing(reporter: reporter)
            try await scenarioAutoScrollReachesEnd(reporter: reporter)
            try await scenarioAutoScrollWithoutMovement(reporter: reporter)
        } catch {
            reporter.fail("harness crashed: \(error)")
        }

        reporter.finish()
    }

    // MARK: - Scenarios

    private static func scenarioMainScroll(reporter: Reporter) async throws {
        // 4000 pt document, 400 pt viewport, 150 pt steps, one wiggle.
        var tops: [Double] = stride(from: 0.0, through: 3600.0, by: 150.0).map { $0 }
        let wiggleAt = 1500.0
        if let index = tops.firstIndex(of: wiggleAt) {
            tops.insert(contentsOf: [wiggleAt - 150, wiggleAt], at: index + 1)
        }

        let run = ProcessorRun(maxHeight: 100_000)
        for top in tops {
            run.processor.enqueue(try renderFrame(topPt: top))
            try await Task.sleep(nanoseconds: 350_000_000)
        }
        let result = try await drain(run: run, expectAutomatic: false)

        reporter.check(result?.reason == .stopped, "main scroll finishes as .stopped")
        guard let image = result?.image else {
            reporter.fail("main scroll produced no image")
            return
        }
        reporter.check(image.width == 1200, "stitched width is 1200 px (got \(image.width))")
        reporter.check(
            (7700...8000).contains(image.height),
            "stitched height covers the document (got \(image.height), expected 8000)"
        )
        let bands = bandScan(image)
        reporter.check(bands.first == 0, "stitched image starts at band 0 (got \(bands.first.map(String.init) ?? "nil"))")
        reporter.check(bands.last == 99, "stitched image ends at band 99 (got \(bands.last.map(String.init) ?? "nil"))")
        reporter.check(
            bandsIsMonotonic(bands),
            "bands are strictly ordered with no duplicates (\(Set(bands).count) distinct of 100)"
        )
        if let image = result?.image {
            savePNG(image, to: "/tmp/snipbo-scroll-verify.png")
        }
    }

    /// Starting mid-document and scrolling up to the top before scrolling down
    /// past the start must still produce the whole document: upward frames are
    /// prepended, downward frames appended, with no duplicates or gaps.
    private static func scenarioUpThenDown(reporter: Reporter) async throws {
        let run = ProcessorRun(maxHeight: 100_000)
        var tops = stride(from: 1200.0, through: 0.0, by: -150.0).map { $0 }
        tops += stride(from: 150.0, through: 3600.0, by: 150.0).map { $0 }
        for top in tops {
            run.processor.enqueue(try renderFrame(topPt: top))
            try await Task.sleep(nanoseconds: 350_000_000)
        }
        let result = try await drain(run: run, expectAutomatic: false)
        reporter.check(result?.reason == .stopped, "up-then-down finishes as .stopped")
        guard let image = result?.image else {
            reporter.fail("up-then-down produced no image")
            return
        }
        let bands = bandScan(image)
        reporter.check(
            bands.first == 0,
            "up-then-down starts at band 0 (got \(bands.first.map(String.init) ?? "nil"))"
        )
        reporter.check(
            bands.last == 99,
            "up-then-down ends at band 99 (got \(bands.last.map(String.init) ?? "nil"))"
        )
        reporter.check(
            Set(bands).count == 100,
            "up-then-down keeps every band (got \(Set(bands).count))"
        )
        reporter.check(
            bandsIsMonotonic(bands),
            "up-then-down bands are ordered with no duplicates"
        )
        savePNG(image, to: "/tmp/snipbo-scroll-updown.png")
    }

    private static func scenarioNoMovement(reporter: Reporter) async throws {
        let run = ProcessorRun(maxHeight: 100_000)
        for _ in 0..<3 {
            run.processor.enqueue(try renderFrame(topPt: 0))
            try await Task.sleep(nanoseconds: 350_000_000)
        }
        let result = try await drain(run: run, expectAutomatic: false)
        reporter.check(result?.reason == .noMovement, "a still page reports .noMovement")
        reporter.check(result?.image.height == 800, "a still page keeps the first frame only")
    }

    private static func scenarioHeightLimit(reporter: Reporter) async throws {
        let run = ProcessorRun(maxHeight: 1200)
        run.processor.enqueue(try renderFrame(topPt: 0))
        try await Task.sleep(nanoseconds: 350_000_000)
        run.processor.enqueue(try renderFrame(topPt: 150))
        try await Task.sleep(nanoseconds: 350_000_000)
        run.processor.enqueue(try renderFrame(topPt: 300))
        let automatic = try await drain(run: run, expectAutomatic: true)
        reporter.check(automatic?.reason == .limitReached, "height limit finishes automatically as .limitReached")
        reporter.check(automatic?.image.height == 1200, "height limit truncates to exactly 1200 px (got \(automatic?.image.height ?? -1))")
    }

    private static func scenarioUpwardScrollAppendsNothing(reporter: Reporter) async throws {
        let run = ProcessorRun(maxHeight: 100_000)
        run.processor.enqueue(try renderFrame(topPt: 0))
        try await Task.sleep(nanoseconds: 350_000_000)
        run.processor.enqueue(try renderFrame(topPt: 150))
        try await Task.sleep(nanoseconds: 350_000_000)
        run.processor.enqueue(try renderFrame(topPt: 0)) // scroll back up
        try await Task.sleep(nanoseconds: 350_000_000)
        let result = try await drain(run: run, expectAutomatic: false)
        reporter.check(result?.reason == .stopped, "up-scroll run finishes as .stopped")
        reporter.check(result?.image.height == 1100, "up-scroll appends nothing (got \(result?.image.height ?? -1), expected 1100)")
    }

    /// Auto-scroll posts wheel events until the viewport stops changing, which
    /// is also what reaching the end of a document looks like. Content already
    /// stitched must still be delivered, not discarded as "no movement".
    private static func scenarioAutoScrollReachesEnd(reporter: Reporter) async throws {
        let run = ProcessorRun(maxHeight: 100_000, autoScroll: true)
        for top in stride(from: 0.0, through: 600.0, by: 150.0) {
            run.processor.enqueue(try renderFrame(topPt: top))
            try await Task.sleep(nanoseconds: 350_000_000)
        }
        for _ in 0..<28 {
            run.processor.enqueue(try renderFrame(topPt: 600))
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        let automatic = try await drain(run: run, expectAutomatic: true)
        reporter.check(
            automatic?.reason == .stopped,
            "auto-scroll that reaches the end finishes as .stopped (got \(automatic.map { String(describing: $0.reason) } ?? "nil"))"
        )
        reporter.check(
            (automatic?.image.height ?? 0) > 800,
            "auto-scroll keeps the stitched content (got \(automatic?.image.height ?? 0) px, expected > 800)"
        )
    }

    /// The pointer sitting on a non-scrollable area is the one case where
    /// discarding the capture is still right.
    private static func scenarioAutoScrollWithoutMovement(reporter: Reporter) async throws {
        let run = ProcessorRun(maxHeight: 100_000, autoScroll: true)
        for _ in 0..<28 {
            run.processor.enqueue(try renderFrame(topPt: 0))
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        let automatic = try await drain(run: run, expectAutomatic: true)
        reporter.check(
            automatic?.reason == .noMovement,
            "auto-scroll over a still page reports .noMovement (got \(automatic.map { String(describing: $0.reason) } ?? "nil"))"
        )
        reporter.check(
            automatic?.image.height == 800,
            "a still page keeps only the first frame (got \(automatic?.image.height ?? -1))"
        )
    }

    /// Waits out the worker queue and returns the automatic result if one is
    /// expected, otherwise the manual stop result.
    private static func drain(run: ProcessorRun, expectAutomatic: Bool) async throws -> ScrollingCaptureResult? {
        if expectAutomatic {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, run.automaticResult == nil {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            return run.automaticResult
        }
        // Let the last enqueued frame finish processing before stopping.
        try await Task.sleep(nanoseconds: 700_000_000)
        return run.processor.stopAndWait()
    }

    // MARK: - Ruler rendering

    private static let scale: CGFloat = 2
    private static let viewportPx = CGSize(width: 1200, height: 800)
    private static let bandPt: CGFloat = 40
    private static let bandCount = 100

    /// Renders the viewport of a virtual 1200×8000 px ruler document at the
    /// given top offset (in points). Band i paints red channel 40 + 2i, so a
    /// pixel scan identifies every band unambiguously.
    private static func renderFrame(topPt: Double) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: Int(viewportPx.width),
            height: Int(viewportPx.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw HarnessError.fixtureFailed }

        context.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1))
        context.fill(CGRect(origin: .zero, size: viewportPx))

        let firstBand = Int(floor(topPt / Double(bandPt)))
        let lastBand = min(bandCount - 1, Int(ceil((topPt + Double(viewportPx.height / scale)) / Double(bandPt))))
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, 26 * scale, nil)

        for band in max(0, firstBand)...max(0, lastBand) {
            // CGContext is bottom-left oriented; convert document-top rows.
            let bandTopInFrame = CGFloat(band) * bandPt - CGFloat(topPt) // pt from viewport top
            let rectTopPx = bandTopInFrame * scale
            let rect = CGRect(
                x: 0,
                y: viewportPx.height - rectTopPx - bandPt * scale,
                width: viewportPx.width,
                height: bandPt * scale
            )
            let identity = CGFloat(40 + 2 * band) / 255
            context.setFillColor(CGColor(
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                components: [identity, 0.12, 0.24, 1]
            )!)
            context.fill(rect)

            // Fine tick marks give Vision texture inside the band.
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.25))
            for tick in 0..<4 {
                let y = rect.minY + CGFloat(tick) * bandPt * scale / 4
                context.fill(CGRect(x: 0, y: y, width: 14, height: 2))
            }

            let label = String(format: "%03d", band) as CFString
            let attributes: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            ]
            guard let attributed = CFAttributedStringCreate(nil, label, attributes as CFDictionary) else {
                throw HarnessError.fixtureFailed
            }
            let line = CTLineCreateWithAttributedString(attributed)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            context.textPosition = CGPoint(
                x: viewportPx.width / 2 - width / 2,
                y: rect.minY + rect.height / 2 - 9 * scale
            )
            CTLineDraw(line, context)
        }

        guard let image = context.makeImage() else { throw HarnessError.fixtureFailed }
        return image
    }

    // MARK: - Stitched-image verification

    /// Samples the red channel every 40 px down the image at a column clear
    /// of text and ticks, and maps it back to a band index.
    private static func bandScan(_ image: CGImage) -> [Int] {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        let column = width - 60
        var bands: [Int] = []
        var row = 20
        while row < height {
            let red = bytes[row * width * 4 + column * 4]
            bands.append(Int((Float(red) - 40).rounded() / 2))
            row += 40
        }
        return bands
    }

    private static func bandsIsMonotonic(_ bands: [Int]) -> Bool {
        guard let first = bands.first, first == 0 else { return false }
        var previous = first
        for band in bands.dropFirst() {
            // Within a band the identity repeats; across bands it may jump
            // forward (a coalesced frame) but must never repeat or decrease.
            if band < previous { return false }
            previous = band
        }
        return Set(bands).count >= 98 && bands.last == 99
    }

    private static func savePNG(_ image: CGImage, to path: String) {
        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

/// Owns one processor plus the recorded automatic finish.
final class ProcessorRun: @unchecked Sendable {
    // Implicitly optional so phase-1 init completes before the onFinish
    // closure captures self.
    private(set) var processor: ScrollFrameProcessor!
    private let lock = NSLock()
    private var storedAutomaticResult: ScrollingCaptureResult?

    init(maxHeight: Int, autoScroll: Bool = false) {
        processor = ScrollFrameProcessor(
            maxHeight: maxHeight,
            autoScroll: autoScroll,
            onProgress: { _ in },
            onFinish: { [weak self] result in
                guard let self else { return }
                lock.lock()
                storedAutomaticResult = try? result.get()
                lock.unlock()
            }
        )
    }

    var automaticResult: ScrollingCaptureResult? {
        lock.lock()
        defer { lock.unlock() }
        return storedAutomaticResult
    }
}

enum HarnessError: Error {
    case fixtureFailed
}

final class Reporter {
    private var checks = 0
    private var failures = 0

    func check(_ condition: Bool, _ name: String) {
        checks += 1
        print(condition ? "PASS  \(name)" : "FAIL  \(name)")
        if !condition { failures += 1 }
    }

    func fail(_ name: String) {
        checks += 1
        failures += 1
        print("FAIL  \(name)")
    }

    func finish() {
        print("\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
