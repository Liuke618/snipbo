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
    case noFrames

    var errorDescription: String? {
        switch self {
        case .displayNotFound:
            return "The display used for scrolling capture is no longer available."
        case .streamFailed(let message):
            return "Scrolling capture could not start: \(message)"
        case .noFrames:
            return "Scrolling capture did not receive any frames."
        }
    }
}

/// Captures one display region with ScreenCaptureKit and aligns/stitches frames
/// on a serial queue. The class is not main-actor isolated; only the progress
/// and completion callbacks cross to the main actor.
final class ScrollingCaptureSession: @unchecked Sendable {
    private let displayID: CGDirectDisplayID
    private let rect: CGRect
    private let backingScale: CGFloat
    private let maxHeight: Int
    private let onProgress: @MainActor @Sendable (Int) -> Void
    private let onAutomaticFinish: @MainActor @Sendable (Result<ScrollingCaptureResult, Error>) -> Void

    private let stateQueue = DispatchQueue(label: "local.lightshot.scrolling.state")
    private let frameQueue = DispatchQueue(label: "local.lightshot.scrolling.frames")
    private var stream: SCStream?
    private var output: ScrollStreamOutput?
    private var composite: CGImage?
    private var lastFrame: ImageData?
    private var finished = false
    private var appended = false
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
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: frameQueue)
        stateQueue.sync {
            self.stream = stream
            self.output = output
        }
        do {
            try await stream.startCapture()
        } catch {
            throw ScrollingCaptureError.streamFailed(error.localizedDescription)
        }
    }

    /// Stops capture and returns the stitched image, or nil when no new rows
    /// were appended.
    func stop() async -> ScrollingCaptureResult? {
        await stopStream()
        return stateQueue.sync {
            finished = true
            guard let composite, appended else { return nil }
            return ScrollingCaptureResult(image: composite, reason: reason)
        }
    }

    func cancel() async {
        await stopStream()
        stateQueue.sync {
            finished = true
        }
    }

    private func ingest(_ image: CGImage) {
        stateQueue.async { [weak self] in
            self?.process(image)
        }
    }

    private func process(_ image: CGImage) {
        guard !finished, image.width > 0, image.height > 0 else { return }
        let frame = ImageData(image)
        if composite == nil {
            guard let initial = ScrollStitcher.makeInitial(image: image, maxHeight: maxHeight) else {
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
        guard let previous = lastFrame, let composite else { return }
        do {
            let registration = try ScrollRegistrationService.offset(
                previous: previous,
                current: frame
            )
            guard registration.confidence >= 0.2 else {
                reason = .lowConfidence
                finish(.success(ScrollingCaptureResult(image: composite, reason: .lowConfidence)))
                return
            }
            guard registration.offset > 0, registration.offset < image.height else {
                lastFrame = frame
                return
            }
            guard let stitched = ScrollStitcher.append(
                composite: composite,
                frame: image,
                offset: registration.offset,
                maxHeight: maxHeight
            ) else {
                lastFrame = frame
                return
            }
            self.composite = stitched.image
            self.lastFrame = frame
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
        guard !finished else { return }
        finished = true
        Task { [weak self] in
            await self?.stopStream()
            guard let self else { return }
            await MainActor.run {
                self.onAutomaticFinish(result)
            }
        }
    }

    private func report(_ height: Int) {
        Task { @MainActor [onProgress] in
            onProgress(height)
        }
    }

    private func stopStream() async {
        let stream = stateQueue.sync { () -> SCStream? in
            let current = self.stream
            self.stream = nil
            self.output = nil
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
