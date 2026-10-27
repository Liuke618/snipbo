import CoreGraphics
import Foundation
import SnipboCore

/// Aligns and stitches the frames of a scrolling capture. Independent of
/// ScreenCaptureKit so the whole pipeline can be driven from a harness with
/// synthetic frames.
///
/// Scheduling: `enqueue` runs on `stateQueue`, which keeps only the newest
/// pending frame; Vision registration and stitching run one frame at a time
/// on `workQueue`. Frames register against the composite's bottom strip (the
/// live frontier) to append downward, or its top strip to prepend upward, so
/// the stitched image stays continuous through scroll wiggles and a capture
/// started mid-document still ends up whole. Every registration is verified
/// against the actual overlap before anything is stitched, because Vision
/// reports confident matches for content that is not there. `onFinish` fires
/// exactly once, either from an automatic stop (limit reached, low
/// confidence, stream error) or never — a manual `stop()` delivers through
/// its return value instead.
final class ScrollFrameProcessor: @unchecked Sendable {
    private let maxHeight: Int
    private let autoScroll: Bool
    private let onProgress: @MainActor @Sendable (Int) -> Void
    private let onFinish: @Sendable (Result<ScrollingCaptureResult, Error>) -> Void

    private let stateQueue = DispatchQueue(label: "local.snipbo.scrolling.processor.state")
    private let workQueue = DispatchQueue(
        label: "local.snipbo.scrolling.processor.work",
        qos: .userInitiated
    )

    // stateQueue-confined.
    private var finished = false
    private var latestFrame: CGImage?
    private var workerActive = false

    // workQueue-confined.
    private var accumulator: ScrollComposite?
    private var appended = false
    private var effectiveMaxHeight = 0
    private var reportedHeight = 0
    private var reason: ScrollingCaptureReason = .stopped
    private var consecutiveNoStitch = 0

    init(
        maxHeight: Int,
        autoScroll: Bool = false,
        onProgress: @MainActor @Sendable @escaping (Int) -> Void,
        onFinish: @Sendable @escaping (Result<ScrollingCaptureResult, Error>) -> Void
    ) {
        self.maxHeight = maxHeight
        self.autoScroll = autoScroll
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    func enqueue(_ image: CGImage) {
        stateQueue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.latestFrame = image
            // When a worker is draining, it picks up the newest frame; the
            // intermediate ones are dropped instead of piling up.
            guard !self.workerActive else { return }
            self.workerActive = true
            self.workQueue.async { [weak self] in
                self?.drain()
            }
        }
    }

    /// Stops and returns the stitched image, waiting out the in-flight frame.
    /// A composite that never grew reports `.noMovement`; nil means not even
    /// a first frame arrived.
    func stopAndWait() -> ScrollingCaptureResult? {
        workQueue.sync { () -> ScrollingCaptureResult? in
            stateQueue.sync {
                finished = true
                latestFrame = nil
            }
            guard let accumulator,
                  let image = accumulator.makeImage() else { return nil }
            return ScrollingCaptureResult(
                image: image,
                reason: appended ? reason : .noMovement
            )
        }
    }

    func cancel() {
        stateQueue.sync {
            finished = true
            latestFrame = nil
        }
    }

    /// Aborts with an error (e.g. a stream failure reported by the delegate).
    func abort(_ error: Error) {
        finish(.failure(error))
    }

    private func drain() {
        while let frame = takeNextFrame() {
            process(frame)
        }
    }

    /// Returns the newest queued frame, or clears `workerActive` when the
    /// queue is empty so the next enqueue schedules a fresh worker. Both
    /// happen under one `stateQueue.sync`, so no frame can be lost in between.
    private func takeNextFrame() -> CGImage? {
        stateQueue.sync { () -> CGImage? in
            guard !finished else {
                workerActive = false
                latestFrame = nil
                return nil
            }
            if let frame = latestFrame {
                latestFrame = nil
                return frame
            }
            workerActive = false
            return nil
        }
    }

    private func process(_ image: CGImage) {
        guard !stateQueue.sync(execute: { finished }), image.width > 0, image.height > 0 else { return }
        if accumulator == nil {
            // Pin the height budget once, from the first frame's width.
            effectiveMaxHeight = ScrollAlignment.effectiveMaxHeight(
                requested: maxHeight,
                width: image.width
            )
            guard let accumulator = ScrollComposite(
                image: image,
                maxHeight: effectiveMaxHeight
            ) else {
                finish(.failure(ScrollingCaptureError.compositionFailed))
                return
            }
            self.accumulator = accumulator
            ScrollDebugLog.log("first frame composited: \(image.width)x\(accumulator.height), effectiveMax=\(effectiveMaxHeight)")
            report(accumulator.height)
            if accumulator.reachedLimit {
                reason = .limitReached
                finishWithImage(accumulator, reason: .limitReached)
            }
            return
        }
        guard let current = accumulator else { return }
        // The strip is one viewport tall, bounded by the composite for short
        // captures. Below the minimum verifiable overlap nothing is appended.
        let stripHeight = min(image.height, current.height)
        guard stripHeight >= ScrollOverlap.minimumRows else { return }

        var stitched = false
        // Downward scrolls extend the composite below its bottom frontier.
        if appendFrame(image, composite: current, stripHeight: stripHeight) {
            stitched = true
        } else {
            guard !stateQueue.sync(execute: { finished }) else { return }
            // Upward scrolls extend it above the top frontier, so a capture
            // started mid-document still ends up whole.
            stitched = prependFrame(image, composite: current, stripHeight: stripHeight)
        }
        guard stitched else {
            // Auto-scroll keeps posting wheel events, so a long run with no
            // new content means the viewport reached its end (or the pointer
            // is not over a scrollable area). Finish instead of scrolling
            // forever.
            if autoScroll {
                consecutiveNoStitch += 1
                if consecutiveNoStitch >= 25 {
                    // Reaching the end of the document looks identical to never
                    // scrolling; only discard the capture when nothing was
                    // ever appended.
                    let endReason: ScrollingCaptureReason = appended ? .stopped : .noMovement
                    reason = endReason
                    finishWithImage(current, reason: endReason)
                }
            }
            return
        }
        consecutiveNoStitch = 0
        appended = true
        report(current.height)
        if current.reachedLimit {
            reason = .limitReached
            finishWithImage(current, reason: .limitReached)
        }
    }

    private func finishWithImage(_ composite: ScrollComposite, reason: ScrollingCaptureReason) {
        guard let image = composite.makeImage() else {
            finish(.failure(ScrollingCaptureError.compositionFailed))
            return
        }
        finish(.success(ScrollingCaptureResult(image: image, reason: reason)))
    }

    /// Registers against the composite's bottom strip and appends only when
    /// the implied overlap is structurally verified. Vision reports a
    /// confident match even when the strip is absent (repeated chat layouts),
    /// which used to append unrelated rows and duplicate content.
    private func appendFrame(
        _ image: CGImage,
        composite current: ScrollComposite,
        stripHeight: Int
    ) -> Bool {
        guard let strip = current.bottomStrip(rows: stripHeight) else { return false }
        do {
            let registration = try ScrollRegistrationService.offset(
                previous: ImageData(strip),
                current: ImageData(image)
            )
            ScrollDebugLog.log("reg bottom: stripH=\(stripHeight) frameH=\(image.height) ty=\(registration.translationY) conf=\(registration.confidence)")
            guard registration.confidence >= 0.2 else {
                reason = .lowConfidence
                finishWithImage(current, reason: .lowConfidence)
                return false
            }
            guard let skip = ScrollAlignment.frontierSkipRows(
                translationY: registration.translationY,
                stripHeight: stripHeight,
                frameHeight: image.height
            ) else { return false }
            // The strip's top `translationY` rows scrolled out of view; the
            // remaining rows are the part that must match the frame's top.
            let overlapRows = stripHeight - registration.translationY
            guard ScrollOverlap.confidentlyOverlaps(
                composite: strip,
                frame: image,
                compositeRowOffset: registration.translationY,
                frameRowOffset: 0,
                rows: overlapRows
            ) else {
                ScrollDebugLog.log("reject append: ty=\(registration.translationY) overlap=\(overlapRows) (unverified)")
                return false
            }
            guard current.append(frame: image, offset: skip) else {
                ScrollDebugLog.log("skip: ty=\(registration.translationY) stripH=\(stripHeight)")
                return false
            }
            ScrollDebugLog.log("append: skip=\(skip) newH=\(current.height)")
            return true
        } catch {
            // A single hopeless frame must not abort a long capture.
            return false
        }
    }

    /// Registers against the composite's top strip and prepends the rows a
    /// frame contributes above it, with the same overlap verification.
    private func prependFrame(
        _ image: CGImage,
        composite current: ScrollComposite,
        stripHeight: Int
    ) -> Bool {
        guard let strip = current.topStrip(rows: stripHeight) else { return false }
        do {
            let registration = try ScrollRegistrationService.offset(
                previous: ImageData(strip),
                current: ImageData(image)
            )
            ScrollDebugLog.log("reg top: stripH=\(stripHeight) frameH=\(image.height) ty=\(registration.translationY) conf=\(registration.confidence)")
            guard registration.confidence >= 0.2 else { return false }
            guard let rows = ScrollAlignment.leadingRows(
                translationY: registration.translationY,
                stripHeight: stripHeight,
                frameHeight: image.height
            ) else { return false }
            let overlapRows = stripHeight - rows
            guard ScrollOverlap.confidentlyOverlaps(
                composite: strip,
                frame: image,
                compositeRowOffset: 0,
                frameRowOffset: rows,
                rows: overlapRows
            ) else {
                ScrollDebugLog.log("reject prepend: ty=\(registration.translationY) overlap=\(overlapRows) (unverified)")
                return false
            }
            guard current.prepend(frame: image, rows: rows) else {
                ScrollDebugLog.log("skip prepend: ty=\(registration.translationY) stripH=\(stripHeight)")
                return false
            }
            ScrollDebugLog.log("prepend: rows=\(rows) newH=\(current.height)")
            return true
        } catch {
            return false
        }
    }

    private func finish(_ result: Result<ScrollingCaptureResult, Error>) {
        let shouldDeliver: Bool = stateQueue.sync { () -> Bool in
            guard !finished else { return false }
            finished = true
            latestFrame = nil
            return true
        }
        guard shouldDeliver else { return }
        onFinish(result)
    }

    private func report(_ height: Int) {
        // Heights are strictly increasing; the guard keeps a reordered
        // main-actor hop from moving the label backwards.
        guard height > reportedHeight else { return }
        reportedHeight = height
        Task { @MainActor [onProgress] in
            onProgress(height)
        }
    }
}
