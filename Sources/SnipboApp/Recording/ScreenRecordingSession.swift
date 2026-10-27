import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import SnipboCore
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers
import VideoToolbox

enum RecordingError: Error, LocalizedError, Sendable {
    case displayNotFound
    case streamFailed(String)
    case streamError(String)
    case noFrames
    case writerFailed(String)
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .displayNotFound:
            return L10n.tr(
                "The display used for recording is no longer available.",
                "录制使用的显示器已不可用。"
            )
        case .streamFailed(let message):
            return L10n.tr("Recording could not start: \(message)", "录制无法启动：\(message)")
        case .streamError(let message):
            return L10n.tr("Recording failed: \(message)", "录制失败：\(message)")
        case .noFrames:
            return L10n.tr("No frames were recorded.", "没有录到任何画面。")
        case .writerFailed(let message):
            return L10n.tr("The recording could not be saved: \(message)", "录制文件保存失败：\(message)")
        case .encodeFailed:
            return L10n.tr("The recording could not be encoded.", "录制文件编码失败。")
        }
    }
}

/// Records a display region to MP4 or GIF. ScreenCaptureKit supplies BGRA
/// frames; MP4 goes through AVAssetWriter, GIF is collected as downscaled
/// frames and encoded at stop. Snipbo's own windows are excluded by the content
/// filter, so the floating recording controls never appear in the output.
final class ScreenRecordingSession: NSObject, @unchecked Sendable {
    private let displayID: CGDirectDisplayID
    private let rect: CGRect
    private let backingScale: CGFloat
    private let fps: Int
    private let format: RecordingFormat
    private let maxSeconds: Int
    private let gifMaxWidth: Int
    private let outputURL: URL
    private let showsCursor: Bool
    private let onAutomaticFinish: @MainActor @Sendable (Result<URL, Error>) -> Void

    private let stateQueue = DispatchQueue(label: "local.snipbo.recording.state")
    private let workQueue = DispatchQueue(
        label: "local.snipbo.recording.frames",
        qos: .userInitiated
    )

    // stateQueue-confined.
    private var stream: SCStream?
    private var output: RecordingStreamOutput?
    private var delegate: RecordingStreamDelegate?
    private var started = false
    private var cancelled = false
    private var finishStarted = false
    private var finalResult: Result<URL, Error>?
    private var maxDurationTimer: DispatchSourceTimer?

    // workQueue-confined.
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var writerStarted = false
    private var gifFrames: [CGImage] = []
    private let gifMaxFrames = 300

    private var streamFPS: Int {
        format == .gif ? min(fps, 15) : fps
    }

    init(
        displayID: CGDirectDisplayID,
        rect: CGRect,
        backingScale: CGFloat,
        fps: Int,
        format: RecordingFormat,
        maxSeconds: Int,
        gifMaxWidth: Int,
        outputURL: URL,
        showsCursor: Bool,
        onAutomaticFinish: @MainActor @Sendable @escaping (Result<URL, Error>) -> Void
    ) {
        self.displayID = displayID
        self.rect = rect
        self.backingScale = backingScale
        self.fps = fps
        self.format = format
        self.maxSeconds = maxSeconds
        self.gifMaxWidth = gifMaxWidth
        self.outputURL = outputURL
        self.showsCursor = showsCursor
        self.onAutomaticFinish = onAutomaticFinish
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw RecordingError.displayNotFound
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownWindows = content.windows.filter {
            $0.owningApplication?.processID == ownPID
        }

        var pixelWidth = max(1, Int((rect.width * backingScale).rounded()))
        var pixelHeight = max(1, Int((rect.height * backingScale).rounded()))
        if format == .mp4 {
            // H.264 encoders are happiest with even dimensions.
            pixelWidth = max(2, (pixelWidth / 2) * 2)
            pixelHeight = max(2, (pixelHeight / 2) * 2)
            try prepareWriter(width: pixelWidth, height: pixelHeight)
        }

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = rect
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(max(1, streamFPS))
        )
        configuration.queueDepth = 6
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = showsCursor
        configuration.captureResolution = .best

        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let delegate = RecordingStreamDelegate { [weak self] message in
            self?.fail(RecordingError.streamError(message))
        }
        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: delegate
        )
        let output = RecordingStreamOutput { [weak self] sampleBuffer in
            self?.handle(sampleBuffer)
        }

        let shouldStart: Bool = stateQueue.sync {
            guard !started, !cancelled else { return false }
            started = true
            self.stream = stream
            self.output = output
            self.delegate = delegate
            return true
        }
        guard shouldStart else { return }

        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: workQueue)
        do {
            try await stream.startCapture()
        } catch {
            stateQueue.sync {
                self.stream = nil
                self.output = nil
                self.delegate = nil
            }
            throw RecordingError.streamFailed(error.localizedDescription)
        }
        scheduleMaxDuration()
    }

    /// Stops and finalizes the recording. Safe to call more than once; the
    /// first caller performs the work and later callers receive the same result.
    func stop() async -> Result<URL, Error> {
        let shouldFinalize: Bool = stateQueue.sync {
            guard finalResult == nil, !finishStarted else { return false }
            finishStarted = true
            return true
        }
        if shouldFinalize {
            await stopStream()
            let result = finalizeOutput()
            stateQueue.sync {
                finalResult = result
            }
            return result
        }
        for _ in 0..<200 {
            if let result = stateQueue.sync(execute: { finalResult }) {
                return result
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return .failure(RecordingError.writerFailed("Timed out while finishing"))
    }

    func cancel() async {
        let shouldCancel: Bool = stateQueue.sync {
            guard finalResult == nil, !finishStarted else { return false }
            finishStarted = true
            cancelled = true
            return true
        }
        guard shouldCancel else { return }
        await stopStream()
        try? FileManager.default.removeItem(at: outputURL)
        stateQueue.sync {
            finalResult = .failure(CancellationError())
        }
    }

    // MARK: - Frames

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        let cancelled = stateQueue.sync { self.cancelled || finalResult != nil }
        guard !cancelled,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        switch format {
        case .mp4:
            appendVideoFrame(pixelBuffer, sampleBuffer: sampleBuffer)
        case .gif:
            appendGIFFrame(pixelBuffer)
        }
    }

    private func appendVideoFrame(
        _ pixelBuffer: CVPixelBuffer,
        sampleBuffer: CMSampleBuffer
    ) {
        guard let writer, let writerInput, let adaptor else { return }
        if writer.status == .unknown {
            guard writer.startWriting() else {
                fail(RecordingError.writerFailed(
                    writer.error?.localizedDescription ?? "startWriting failed"
                ))
                return
            }
            let start = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: start)
            writerStarted = true
        }
        guard writer.status == .writing, writerInput.isReadyForMoreMediaData else {
            return
        }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !adaptor.append(pixelBuffer, withPresentationTime: time) {
            fail(RecordingError.writerFailed(
                writer.error?.localizedDescription ?? "append failed"
            ))
        }
    }

    private func appendGIFFrame(_ pixelBuffer: CVPixelBuffer) {
        guard gifFrames.count < gifMaxFrames else { return }
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(
            pixelBuffer,
            options: nil,
            imageOut: &image
        ) == noErr, let image else {
            return
        }
        let target = gifTargetSize(for: image)
        gifFrames.append(ImageExporter.resampled(image, to: target))
        if gifFrames.count >= gifMaxFrames {
            finishAutomatically()
        }
    }

    private func gifTargetSize(for image: CGImage) -> CGSize {
        let maxWidth = max(1, gifMaxWidth)
        guard image.width > maxWidth else {
            return CGSize(width: image.width, height: image.height)
        }
        let factor = CGFloat(maxWidth) / CGFloat(image.width)
        return CGSize(
            width: maxWidth,
            height: max(1, Int((CGFloat(image.height) * factor).rounded()))
        )
    }

    // MARK: - Lifecycle

    private func scheduleMaxDuration() {
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + .seconds(max(1, maxSeconds)))
        timer.setEventHandler { [weak self] in
            self?.finishAutomatically()
        }
        timer.resume()
        stateQueue.sync {
            maxDurationTimer = timer
        }
    }

    private func finishAutomatically() {
        let shouldFinish = stateQueue.sync {
            finalResult == nil && !finishStarted && !cancelled
        }
        guard shouldFinish else { return }
        Task { [weak self] in
            guard let self else { return }
            let result = await self.stop()
            await MainActor.run {
                self.onAutomaticFinish(result)
            }
        }
    }

    private func fail(_ error: Error) {
        let shouldFail = stateQueue.sync {
            guard finalResult == nil, !finishStarted else { return false }
            finishStarted = true
            cancelled = true
            return true
        }
        guard shouldFail else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.stopStream()
            try? FileManager.default.removeItem(at: self.outputURL)
            self.stateQueue.sync {
                self.finalResult = .failure(error)
            }
            await MainActor.run {
                self.onAutomaticFinish(.failure(error))
            }
        }
    }

    private func stopStream() async {
        let timer = stateQueue.sync { () -> DispatchSourceTimer? in
            let current = maxDurationTimer
            maxDurationTimer = nil
            return current
        }
        timer?.cancel()

        let (stream, output, delegate) = stateQueue.sync {
            () -> (SCStream?, RecordingStreamOutput?, RecordingStreamDelegate?) in
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
        // Drain any in-flight sample callback before finalizing the writer.
        workQueue.sync {}
        _ = output
        _ = delegate
    }

    // MARK: - Output

    private func prepareWriter(width: Int, height: Int) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )
        guard writer.canAdd(input) else {
            throw RecordingError.writerFailed("The writer rejected the video input.")
        }
        writer.add(input)
        self.writer = writer
        self.writerInput = input
        self.adaptor = adaptor
    }

    private func finalizeOutput() -> Result<URL, Error> {
        workQueue.sync {
            switch format {
            case .mp4:
                guard let writer, let writerInput, writerStarted else {
                    try? FileManager.default.removeItem(at: outputURL)
                    return .failure(RecordingError.noFrames)
                }
                writerInput.markAsFinished()
                let semaphore = DispatchSemaphore(value: 0)
                writer.finishWriting {
                    semaphore.signal()
                }
                semaphore.wait()
                guard writer.status == .completed else {
                    try? FileManager.default.removeItem(at: outputURL)
                    return .failure(RecordingError.writerFailed(
                        writer.error?.localizedDescription ?? "finishWriting failed"
                    ))
                }
                return .success(outputURL)
            case .gif:
                guard !gifFrames.isEmpty else {
                    try? FileManager.default.removeItem(at: outputURL)
                    return .failure(RecordingError.noFrames)
                }
                do {
                    try writeGIF()
                    return .success(outputURL)
                } catch {
                    try? FileManager.default.removeItem(at: outputURL)
                    return .failure(error)
                }
            }
        }
    }

    private func writeGIF() throws {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            gifFrames.count,
            nil
        ) else {
            throw RecordingError.encodeFailed
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0,
            ],
        ] as CFDictionary)
        let delay = 1.0 / Double(max(1, streamFPS))
        for frame in gifFrames {
            CGImageDestinationAddImage(destination, frame, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ],
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw RecordingError.encodeFailed
        }
    }
}

private final class RecordingStreamOutput: NSObject, SCStreamOutput {
    private let onSample: @Sendable (CMSampleBuffer) -> Void

    init(onSample: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.onSample = onSample
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }
        onSample(sampleBuffer)
    }
}

private final class RecordingStreamDelegate: NSObject, SCStreamDelegate {
    private let onError: @Sendable (String) -> Void

    init(onError: @escaping @Sendable (String) -> Void) {
        self.onError = onError
    }

    func stream(_ stream: SCStream, didCaptureWithError error: Error) {
        onError(error.localizedDescription)
    }
}
