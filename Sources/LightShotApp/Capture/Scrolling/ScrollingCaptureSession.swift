import AppKit
import CoreMedia
import LightShotCore
import ScreenCaptureKit
import VideoToolbox

enum ScrollingCaptureReason: Equatable, Sendable {
    case stopped
    case limitReached
    case lowConfidence
    case noMovement
}

struct ScrollingCaptureResult: @unchecked Sendable {
    let image: CGImage
    let reason: ScrollingCaptureReason
}

enum ScrollingCaptureError: Error, LocalizedError, Sendable {
    case displayNotFound
    case streamFailed(String)
    case streamError(String)
    case noFrames

    var errorDescription: String? {
        switch self {
        case .displayNotFound:
            return "The display used for scrolling capture is no longer available."
        case .streamFailed(let message):
            return "Scrolling capture could not start: \(message)"
        case .streamError(let message):
            return "Scrolling capture failed: \(message)"
        case .noFrames:
            return "Scrolling capture did not receive any frames."
        }
    }
}

/// Captures one display region with ScreenCaptureKit and aligns/stitches
/// frames. Frames land on `frameQueue` (cheap pixel-buffer conversion only);
/// `stateQueue` guards the scheduling flags and keeps only the newest pending
/// frame; Vision registration and stitching run one frame at a time on
/// `workQueue`. Completion crosses to the main actor exactly once via
/// `onAutomaticFinish`; `stop()` delivers instead and must not race it.
final class ScrollingCaptureSession: @unchecked Sendable {
    private let displayID: CGDirectDisplayID
    private let rect: CGRect
    private let backingScale: CGFloat
    private let maxHeight: Int
    private let onProgress: @MainActor @Sendable (Int) -> Void
    private let onAutomaticFinish: @MainActor @Sendable (Result<ScrollingCaptureResult, Error>) -> Void

    private let stateQueue = DispatchQueue(label: "local.lightshot.scrolling.state")
    private let frameQueue = DispatchQueue(label: "local.lightshot.scrolling.frames")
    private let workQueue = DispatchQueue(label: "local.lightshot.scrolling.work", qos: .userInitiated)

    // stateQueue-confined.
    private var stream: SCStream?
    private var delegate: ScrollStreamDelegate?
    private var finished = false
    private var latestFrame: CGImage?
    private var workerActive = false

    // workQueue-confined.
    private var composite: CGImage?
    private var lastFrame: ImageData?
    private var appended = false
    private var effectiveMaxHeight = 0
    private var reportedHeight = 0
    private var reason: ScrollingCaptureReason = .stopped

    init(
        displayID: CGDirectDisplayID,
        rect: CGRect,
        backingScale: CGFloat,
        maxHeight: Int,
        onProgress: @MainActor @Sendable @escaping (Int) -> Void,
        onAutomaticFinish: @MainActor @Sendable @escaping (Result<ScrollingCaptureResult, Error>) -> Void
    ) {
        self.displayID = displayID
        self.rect = rect
        self.backingScale = backingScale
        self.maxHeight = maxHeight
        self.onProgress = onProgress
        self.onAutomaticFinish = onAutomaticFinish
    }

    func start() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScrollingCaptureError.displayNotFound
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownWindows = content.windows.filter {
            $0.owningApplication?.processID == ownPID
        }

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = rect
        configuration.width = max(1, Int((rect.width * backingScale).rounded()))
        configuration.height = max(1, Int((rect.height * backingScale).rounded()))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false

        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let output = ScrollStreamOutput { [weak self] image in
            self?.ingest(image)
        }
        let delegate = ScrollStreamDelegate { [weak self] message in
            self?.handleStreamError(message)
        }
        // The user may have cancelled while shareable content was loading;
        // never start a stream for an already-finished capture.
        var shouldStart = false
        stateQueue.sync {
            if !self.finished {
                self.stream = stream
                self.delegate = delegate
                shouldStart = true
            }
        }
        guard shouldStart else { return }
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: frameQueue)
        do {
            try await stream.startCapture()
        } catch {
            stateQueue.sync {
                self.stream = nil
                self.delegate = nil
            }
            throw ScrollingCaptureError.streamFailed(error.localizedDescription)
        }
    }

    /// Stops capture and returns the stitched image. A composite that never
    /// grew reports `.noMovement`; nil means not even a first frame arrived.
    func stop() async -> ScrollingCaptureResult? {
        await stopStream()
        // Wait out the in-flight frame so the composite is final.
        return workQueue.sync { () -> ScrollingCaptureResult? in
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

    func cancel() async {
        await stopStream()
        stateQueue.sync {
            finished = true
            latestFrame = nil
        }
    }

    private func ingest(_ image: CGImage) {
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

    private func drain() {
        while let frame = takeNextFrame() {
            process(frame)
        }
    }

    /// Returns the newest queued frame, or clears `workerActive` when the
    /// queue is empty so the next ingest schedules a fresh worker. Both happen
    /// under one `stateQueue.sync`, so no frame can be lost in between.
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
            lastFrame = frame
            report(initial.image.height)
            if initial.reachedLimit {
                reason = .limitReached
                finish(.success(ScrollingCaptureResult(image: initial.image, reason: .limitReached)))
            }
            return
        }
        guard let previous = lastFrame, let current = composite else { return }
        do {
            let registration = try ScrollRegistrationService.offset(
                previous: previous,
                current: frame
            )
            guard registration.confidence >= 0.2 else {
                reason = .lowConfidence
                finish(.success(ScrollingCaptureResult(image: current, reason: .lowConfidence)))
                return
            }
            guard let overlap = ScrollAlignment.overlapRows(
                translationY: registration.translationY,
                frameHeight: image.height
            ) else {
                // No movement, an upward scroll, or an implausible jump: keep
                // the newest frame as the next reference and wait.
                lastFrame = frame
                return
            }
            guard let stitched = ScrollStitcher.append(
                composite: current,
                frame: image,
                offset: overlap,
                maxHeight: effectiveMaxHeight
            ) else {
                lastFrame = frame
                return
            }
            composite = stitched.image
            lastFrame = frame
            appended = true
            report(stitched.image.height)
            if stitched.reachedLimit {
                reason = .limitReached
                finish(.success(ScrollingCaptureResult(image: stitched.image, reason: .limitReached)))
            }
        } catch {
            // A single hopeless frame must not abort a long capture; keep the
            // previous composite and try the next one.
            lastFrame = frame
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
        Task { [weak self] in
            await self?.stopStream()
            guard let self else { return }
            await MainActor.run {
                self.onAutomaticFinish(result)
            }
        }
    }

    private func handleStreamError(_ message: String) {
        finish(.failure(ScrollingCaptureError.streamError(message)))
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

    private func stopStream() async {
        let stream = stateQueue.sync { () -> SCStream? in
            let current = self.stream
            self.stream = nil
            self.delegate = nil
            return current
        }
        if let stream {
            try? await stream.stopCapture()
        }
    }
}

private final class ScrollStreamOutput: NSObject, SCStreamOutput {
    private let onFrame: @Sendable (CGImage) -> Void

    init(onFrame: @escaping @Sendable (CGImage) -> Void) {
        self.onFrame = onFrame
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(
            pixelBuffer,
            options: nil,
            imageOut: &image
        ) == noErr, let image else { return }
        onFrame(image)
    }
}

private final class ScrollStreamDelegate: NSObject, SCStreamDelegate {
    private let onError: @Sendable (String) -> Void

    init(onError: @escaping @Sendable (String) -> Void) {
        self.onError = onError
        super.init()
    }

    func stream(_ stream: SCStream, didCaptureWithError error: Error) {
        onError(error.localizedDescription)
    }
}
