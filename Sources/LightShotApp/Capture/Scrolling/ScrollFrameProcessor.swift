import CoreGraphics
import Foundation
import LightShotCore

/// Aligns and stitches the frames of a scrolling capture. Independent of
/// ScreenCaptureKit so the whole pipeline can be driven from a harness with
/// synthetic frames.
///
/// Scheduling: `enqueue` runs on `stateQueue`, which keeps only the newest
/// pending frame; Vision registration and stitching run one frame at a time
/// on `workQueue`. Frames register against the composite's bottom strip (the
/// live frontier), so skipped upward-scroll frames can never desynchronize
/// the append point from the composite — the stitched image stays continuous
/// through scroll wiggles. `onFinish` fires exactly once, either from an
/// automatic stop (limit reached, low confidence, stream error) or never —
/// a manual `stop()` delivers through its return value instead.
final class ScrollFrameProcessor: @unchecked Sendable {
    private let maxHeight: Int
    private let onProgress: @MainActor @Sendable (Int) -> Void
    private let onFinish: @Sendable (Result<ScrollingCaptureResult, Error>) -> Void

    private let stateQueue = DispatchQueue(label: "local.lightshot.scrolling.processor.state")
    private let workQueue = DispatchQueue(
        label: "local.lightshot.scrolling.processor.work",
        qos: .userInitiated
    )

    // stateQueue-confined.
    private var finished = false
    private var latestFrame: CGImage?
    private var workerActive = false

    // workQueue-confined.
    private var composite: CGImage?
    private var appended = false
    private var effectiveMaxHeight = 0
    private var reportedHeight = 0
    private var reason: ScrollingCaptureReason = .stopped

    init(
        maxHeight: Int,
        onProgress: @MainActor @Sendable @escaping (Int) -> Void,
        onFinish: @Sendable @escaping (Result<ScrollingCaptureResult, Error>) -> Void
    ) {
        self.maxHeight = maxHeight
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
            guard let composite else { return nil }
            return ScrollingCaptureResult(
                image: composite,
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
        let frame = ImageData(image)
        if composite == nil {
            // Pin the height budget once, from the first frame's width.
            effectiveMaxHeight = ScrollAlignment.effectiveMaxHeight(
                requested: maxHeight,
                width: image.width
            )
            guard let initial = ScrollStitcher.makeInitial(image: image, maxHeight: effectiveMaxHeight) else {
                finish(.failure(ScrollingCaptureError.noFrames))
                return
            }
            composite = initial.image
            report(initial.image.height)
            if initial.reachedLimit {
                reason = .limitReached
                finish(.success(ScrollingCaptureResult(image: initial.image, reason: .limitReached)))
            }
            return
        }
        guard let current = composite else { return }
        // Register the frame against the composite's bottom strip: the live
        // capture frontier.
        let stripHeight = min(image.height, current.height)
        guard stripHeight > 0,
              let strip = current.cropping(to: CGRect(
                  x: 0,
                  y: current.height - stripHeight,
                  width: current.width,
                  height: stripHeight
              )) else {
            return
        }
        do {
            let registration = try ScrollRegistrationService.offset(
                previous: ImageData(strip),
                current: frame
            )
            guard registration.confidence >= 0.2 else {
                reason = .lowConfidence
                finish(.success(ScrollingCaptureResult(image: current, reason: .lowConfidence)))
                return
            }
            guard let skip = ScrollAlignment.frontierSkipRows(
                translationY: registration.translationY,
                stripHeight: stripHeight,
                frameHeight: image.height
            ), let stitched = ScrollStitcher.append(
                composite: current,
                frame: image,
                offset: skip,
                maxHeight: effectiveMaxHeight
            ) else {
                // No movement, an upward scroll, or an implausible jump:
                // nothing trustworthy to append; the next frame registers
                // against the same frontier.
                return
            }
            composite = stitched.image
            appended = true
            report(stitched.image.height)
            if stitched.reachedLimit {
                reason = .limitReached
                finish(.success(ScrollingCaptureResult(image: stitched.image, reason: .limitReached)))
            }
        } catch {
            // A single hopeless frame must not abort a long capture; the next
            // frame registers against the same frontier.
            return
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
