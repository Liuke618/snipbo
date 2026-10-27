import AppKit
import CoreMedia
import SnipboCore
@preconcurrency import ScreenCaptureKit
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
    case compositionFailed

    var errorDescription: String? {
        switch self {
        case .displayNotFound:
            return L10n.tr(
                "The display used for scrolling capture is no longer available.",
                "滚动截图使用的显示器已不可用。"
            )
        case .streamFailed(let message):
            return L10n.tr(
                "Scrolling capture could not start: \(message)",
                "滚动截图无法启动：\(message)"
            )
        case .streamError(let message):
            return L10n.tr(
                "Scrolling capture failed: \(message)",
                "滚动截图失败：\(message)"
            )
        case .noFrames:
            return L10n.tr(
                "Scrolling capture did not receive any frames.",
                "滚动截图没有收到任何画面。"
            )
        case .compositionFailed:
            return L10n.tr(
                "The scrolling capture could not be composed.",
                "无法合成滚动截图。"
            )
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
    private let axis: ScrollAxis
    private let autoScroll: Bool
    /// CG-global point at the selection center, moved to before auto-scrolling
    /// so the wheel events land on the intended content.
    private let autoScrollPoint: CGPoint?
    private let onAutomaticFinish: @MainActor @Sendable (Result<ScrollingCaptureResult, Error>) -> Void

    private let stateQueue = DispatchQueue(label: "local.snipbo.scrolling.state")
    private let frameQueue = DispatchQueue(label: "local.snipbo.scrolling.frames")
    private let autoScrollQueue = DispatchQueue(label: "local.snipbo.scrolling.autoscroll")
    // stateQueue-confined.
    private var autoScrollTimer: DispatchSourceTimer?

    // stateQueue-confined. SCStream does not retain its outputs, so the
    // output must be stored here or the frame callback deallocates.
    private var stream: SCStream?
    private var output: ScrollStreamOutput?
    private var delegate: ScrollStreamDelegate?
    private var started = false
    private var cancelled = false

    // Implicitly optional so phase-1 init completes before the onFinish
    // closure captures self.
    private var processor: ScrollFrameProcessor!

    init(
        displayID: CGDirectDisplayID,
        rect: CGRect,
        backingScale: CGFloat,
        maxHeight: Int,
        fps: Int,
        axis: ScrollAxis = .vertical,
        autoScroll: Bool = false,
        autoScrollPoint: CGPoint? = nil,
        onProgress: @MainActor @Sendable @escaping (Int) -> Void,
        onAutomaticFinish: @MainActor @Sendable @escaping (Result<ScrollingCaptureResult, Error>) -> Void
    ) {
        self.displayID = displayID
        self.rect = rect
        self.backingScale = backingScale
        self.fps = fps
        self.axis = axis
        self.autoScroll = autoScroll
        self.autoScrollPoint = autoScrollPoint
        self.onAutomaticFinish = onAutomaticFinish
        self.processor = ScrollFrameProcessor(
            maxHeight: maxHeight,
            autoScroll: autoScroll,
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
        let delegate = ScrollStreamDelegate { [weak self] message in
            self?.processor.abort(ScrollingCaptureError.streamError(message))
        }
        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: delegate
        )
        let output = ScrollStreamOutput { [weak self] image in
            guard let self else { return }
            // Reuse the vertical stitcher for horizontal scrolling: rotate
            // every frame so the horizontal axis becomes vertical, then rotate
            // the finished composite back.
            let prepared: CGImage
            if self.axis == .horizontal,
               let rotated = ImageRotation.rotated90(image, clockwise: true) {
                prepared = rotated
            } else {
                prepared = image
            }
            self.processor.enqueue(prepared)
        }
        // The user may have cancelled while shareable content was loading;
        // never start a stream for an already-finished capture.
        var shouldStart = false
        stateQueue.sync {
            if !self.started && !self.cancelled {
                self.started = true
                self.stream = stream
                self.output = output
                self.delegate = delegate
                shouldStart = true
            }
        }
        guard shouldStart else { return }
        ScrollDebugLog.log("stream start: display=\(displayID) rect=\(rect) scale=\(backingScale) fps=\(fps)")
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: frameQueue)
        // Cancel may have won while we were adding the output; never start a
        // stream for an already-finished capture.
        let stillWanted = stateQueue.sync {
            self.stream === stream && !self.cancelled
        }
        guard stillWanted else {
            try? await stream.stopCapture()
            return
        }
        do {
            try await stream.startCapture()
        } catch {
            stateQueue.sync {
                self.stream = nil
                self.output = nil
                self.delegate = nil
            }
            throw ScrollingCaptureError.streamFailed(error.localizedDescription)
        }
        if autoScroll {
            startAutoScroll()
        }
    }

    /// Posts wheel events to whatever is under the pointer. The user must keep
    /// the pointer over the scrollable content; the floating control panel is
    /// deliberately placed away from the selection.
    private func startAutoScroll() {
        if let point = autoScrollPoint {
            CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: point,
                mouseButton: .left
            )?.post(tap: .cghidEventTap)
        }
        let timer = DispatchSource.makeTimerSource(queue: autoScrollQueue)
        timer.schedule(
            deadline: .now() + 0.5,
            repeating: .milliseconds(100)
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let cancelled = self.stateQueue.sync { self.cancelled }
            guard !cancelled else { return }
            let horizontal = self.axis == .horizontal
            let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: horizontal ? 2 : 1,
                wheel1: horizontal ? 0 : -20,
                wheel2: horizontal ? -20 : 0,
                wheel3: 0
            )
            event?.post(tap: .cghidEventTap)
        }
        timer.resume()
        stateQueue.sync {
            autoScrollTimer = timer
        }
    }

    /// Stops capture and returns the stitched image, waiting out the
    /// in-flight frame.
    func stop() async -> ScrollingCaptureResult? {
        await stopStream()
        let result = processor.stopAndWait()
        ScrollDebugLog.log("stop: \(result.map { "reason=\($0.reason) height=\($0.image.height)" } ?? "no composite (no frames)")")
        return result.map(orientedResult)
    }

    func cancel() async {
        stateQueue.sync { self.cancelled = true }
        await stopStream()
        processor.cancel()
    }

    private func finishAutomatically(_ result: Result<ScrollingCaptureResult, Error>) {
        let oriented: Result<ScrollingCaptureResult, Error>
        switch result {
        case .success(let value):
            oriented = .success(orientedResult(value))
        case .failure(let error):
            oriented = .failure(error)
        }
        Task { [weak self] in
            await self?.stopStream()
            guard let self else { return }
            await MainActor.run {
                self.onAutomaticFinish(oriented)
            }
        }
    }

    private func orientedResult(_ result: ScrollingCaptureResult) -> ScrollingCaptureResult {
        guard axis == .horizontal,
              let image = ImageRotation.rotated90(result.image, clockwise: false) else {
            return result
        }
        return ScrollingCaptureResult(image: image, reason: result.reason)
    }

    private func stopStream() async {
        if let timer = stateQueue.sync(execute: { () -> DispatchSourceTimer? in
            let current = autoScrollTimer
            autoScrollTimer = nil
            return current
        }) {
            timer.cancel()
        }
        let (stream, output, delegate) = stateQueue.sync {
            () -> (SCStream?, ScrollStreamOutput?, ScrollStreamDelegate?) in
            self.cancelled = true
            let current = self.stream
            let currentOutput = self.output
            let currentDelegate = self.delegate
            self.stream = nil
            self.output = nil
            self.delegate = nil
            return (current, currentOutput, currentDelegate)
        }
        if let stream {
            try? await stream.stopCapture()
        }
        // SCStream does not retain its outputs. Keep the locals alive until
        // stopCapture has returned and any in-flight frame callback has
        // drained, otherwise a late callback can touch a deallocated output.
        frameQueue.sync {}
        _ = output
        _ = delegate
    }
}

private final class ScrollStreamOutput: NSObject, SCStreamOutput {
    private let onFrame: @Sendable (CGImage) -> Void
    private var frameCount = 0

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
        ) == noErr, let image else {
            ScrollDebugLog.log("frame convert FAILED")
            return
        }
        frameCount += 1
        if frameCount == 1 {
            ScrollDebugLog.log("first frame: \(image.width)x\(image.height)")
        } else if frameCount % 20 == 0 {
            ScrollDebugLog.log("frame #\(frameCount): \(image.width)x\(image.height)")
        }
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
