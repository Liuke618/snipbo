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

/// Thin SCStream lifecycle around `ScrollFrameProcessor`, which owns the
/// alignment and stitching state. Frames are converted off the main actor on
/// `frameQueue` and handed to the processor; completion crosses to the main
/// actor exactly once.
final class ScrollingCaptureSession: @unchecked Sendable {
    private let displayID: CGDirectDisplayID
    private let rect: CGRect
    private let backingScale: CGFloat
    private let fps: Int
    private let onAutomaticFinish: @MainActor @Sendable (Result<ScrollingCaptureResult, Error>) -> Void

    private let stateQueue = DispatchQueue(label: "local.lightshot.scrolling.state")
    private let frameQueue = DispatchQueue(label: "local.lightshot.scrolling.frames")

    // stateQueue-confined.
    private var stream: SCStream?
    private var delegate: ScrollStreamDelegate?
    private var started = false

    // Implicitly optional so phase-1 init completes before the onFinish
    // closure captures self.
    private var processor: ScrollFrameProcessor!

    init(
        displayID: CGDirectDisplayID,
        rect: CGRect,
        backingScale: CGFloat,
        maxHeight: Int,
        fps: Int,
        onProgress: @MainActor @Sendable @escaping (Int) -> Void,
        onAutomaticFinish: @MainActor @Sendable @escaping (Result<ScrollingCaptureResult, Error>) -> Void
    ) {
        self.displayID = displayID
        self.rect = rect
        self.backingScale = backingScale
        self.fps = fps
        self.onAutomaticFinish = onAutomaticFinish
        self.processor = ScrollFrameProcessor(
            maxHeight: maxHeight,
            onProgress: onProgress,
            onFinish: { [weak self] result in
                self?.finishAutomatically(result)
            }
        )
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
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false

        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let output = ScrollStreamOutput { [weak self] image in
            self?.processor.enqueue(image)
        }
        let delegate = ScrollStreamDelegate { [weak self] message in
            self?.processor.abort(ScrollingCaptureError.streamError(message))
        }
        // The user may have cancelled while shareable content was loading;
        // never start a stream for an already-finished capture.
        var shouldStart = false
        stateQueue.sync {
            if !self.started {
                self.started = true
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

    /// Stops capture and returns the stitched image, waiting out the
    /// in-flight frame.
    func stop() async -> ScrollingCaptureResult? {
        await stopStream()
        return processor.stopAndWait()
    }

    func cancel() async {
        await stopStream()
        processor.cancel()
    }

    private func finishAutomatically(_ result: Result<ScrollingCaptureResult, Error>) {
        Task { [weak self] in
            await self?.stopStream()
            guard let self else { return }
            await MainActor.run {
                self.onAutomaticFinish(result)
            }
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
