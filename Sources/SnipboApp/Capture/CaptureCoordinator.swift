import AppKit
import ApplicationServices
import SnipboCore
import os

@MainActor
final class CaptureCoordinator {
    private let captureService: ScreenCaptureService
    private var settings: AppSettings
    private let history: HistoryStore
    private let lastRegion: LastRegionStore
    private let pasteboardProvider: () -> any PasteboardWriting
    private var overlays: [NSWindow] = []
    private var keyMonitor: Any?
    private var activeView: SelectionOverlayView?
    private var activePicker: WindowPickerView?
    private var countdownController: CountdownController?
    private var isCapturing = false
    private var captureGeneration = 0
    private var captureWatchdog: Task<Void, Never>?
    /// The mode that produced the capture in flight, used to look up its
    /// per-mode delivery actions. Timed captures keep their own mode so they
    /// can differ from the plain region/screen entries.
    private var deliveryMode = "region"
    /// The app active before Snipbo raised its capture UI, used for the
    /// {app} file-name token.
    private var frontmostAppName: String?
    /// One-shot actions supplied by a URL command, overriding the per-mode
    /// settings for the next capture only.
    private var pendingActionsOverride: CaptureActions?

    private enum SelectionPurpose {
        case region
        case scrolling(axis: ScrollAxis, autoScroll: Bool)
        case recording
    }

    private var scrollingSession: ScrollingCaptureSession?
    private var scrollingControl: ScrollingControlController?
    private var scrollingInProgress = false
    private var recordingSession: ScreenRecordingSession?
    private var recordingControl: RecordingControlController?
    private var recordingInProgress = false
    private var recordingOutputURL: URL?
    private var pendingRecordingFormatOverride: RecordingFormat?
    private var scrollingBackingScale: CGFloat = 1
    /// Every open capture editor, retained until its own close callback runs.
    /// The callback removes exactly the editor that closed, so a second
    /// capture can never deallocate (and disable) the first editor.
    private(set) var editors: [EditorWindowController] = []
    private let logger = Logger(subsystem: "local.snipbo.app", category: "Capture")

    init(
        captureService: ScreenCaptureService,
        settings: AppSettings,
        history: HistoryStore,
        lastRegion: LastRegionStore,
        pasteboardProvider: @escaping () -> any PasteboardWriting = { NSPasteboard.general }
    ) {
        self.captureService = captureService
        self.settings = settings
        self.history = history
        self.lastRegion = lastRegion
        self.pasteboardProvider = pasteboardProvider
    }

    /// Applies settings changed in the Settings window. Captures use the new
    /// values immediately; open editors read them through their settings
    /// provider at copy/save time.
    func updateSettings(_ settings: AppSettings) {
        self.settings = settings
    }

    func start(
        _ command: CaptureCommand,
        actionsOverride: CaptureActions? = nil
    ) {
        pendingActionsOverride = actionsOverride
        // Snapshot the active app before Snipbo raises its overlay; by delivery
        // time Snipbo itself would be frontmost.
        frontmostAppName = NSWorkspace.shared.frontmostApplication?.localizedName
        // Activate synchronously inside the menu action / hotkey handler: this
        // is the only point where cooperative activation is granted, and the
        // overlay windows are only composited while the app is active. The
        // capture itself runs async and presents ~200 ms later, when activation
        // requests are already refused on recent macOS versions.
        NSApp.activate(ignoringOtherApps: true)
        switch command {
        case .region:
            startRegionCapture()
        case .window:
            startWindowCapture()
        case .appWindows:
            startAppWindowsCapture()
        case .screen:
            startScreenCapture()
        case .allScreens:
            startAllScreensCapture()
        case .timedRegion:
            startTimedRegionCapture()
        case .timedScreen:
            startTimedScreenCapture()
        case .timedWindow:
            startTimedWindowCapture()
        case .lastRegion:
            startLastRegionCapture()
        case .scrolling:
            startScrollingCapture()
        case .scrollingHorizontal:
            startScrollingCapture(axis: .horizontal)
        case .scrollingAuto:
            startScrollingCapture(autoScroll: true)
        case .recordRegion:
            startRecordRegion()
        case .recordScreen:
            startRecordScreen()
        }
    }

    func startRegionCapture(mode: String = "region") {
        deliveryMode = mode
        guard beginCapture() else { return }
        let generation = captureGeneration
        Task {
            do {
                let captures = try await captureService.captureAllDisplays(
                    includeCursor: settings.captureCursor
                )
                guard endCaptureAttempt(generation) else { return }
                present(captures: captures, purpose: .region)
            } catch {
                guard generation == captureGeneration else { return }
                fail(error)
            }
        }
    }

    private enum AutoScrollDecision {
        case manual
        case cancelled
    }

    /// Synthetic wheel events require Accessibility permission; without it the
    /// system drops them silently. Offer the settings shortcut, or fall back to
    /// manual scrolling.
    private func confirmAutoScrollPermission() -> AutoScrollDecision {
        guard !AXIsProcessTrusted() else { return .manual }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.tr(
            "Auto-scroll needs Accessibility permission",
            "自动滚动需要辅助功能权限"
        )
        alert.informativeText = L10n.tr(
            "Allow Snipbo in System Settings → Privacy & Security → Accessibility, then try again. You can also scroll manually during the capture.",
            "请在 系统设置 → 隐私与安全性 → 辅助功能 中勾选 Snipbo 后重试；也可以改用手动滚动。"
        )
        alert.addButton(withTitle: L10n.tr("Open System Settings", "打开系统设置"))
        alert.addButton(withTitle: L10n.tr("Scroll Manually", "手动滚动"))
        alert.addButton(withTitle: L10n.tr("Cancel", "取消"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ) {
                NSWorkspace.shared.open(url)
            }
            return .cancelled
        case .alertSecondButtonReturn:
            return .manual
        default:
            return .cancelled
        }
    }

    func startScrollingCapture(
        axis: ScrollAxis = .vertical,
        autoScroll: Bool = false
    ) {
        deliveryMode = "scrolling"
        var effectiveAutoScroll = autoScroll
        if effectiveAutoScroll, !AXIsProcessTrusted() {
            switch confirmAutoScrollPermission() {
            case .manual:
                effectiveAutoScroll = false
            case .cancelled:
                return
            }
        }
        guard beginCapture() else { return }
        let generation = captureGeneration
        Task {
            do {
                let captures = try await captureService.captureAllDisplays(includeCursor: false)
                guard endCaptureAttempt(generation) else { return }
                present(
                    captures: captures,
                    purpose: .scrolling(axis: axis, autoScroll: effectiveAutoScroll)
                )
            } catch {
                guard generation == captureGeneration else { return }
                fail(error)
            }
        }
    }

    func startRecordRegion(formatOverride: RecordingFormat? = nil) {
        pendingRecordingFormatOverride = formatOverride
        guard beginCapture() else { return }
        let generation = captureGeneration
        Task {
            do {
                let captures = try await captureService.captureAllDisplays(includeCursor: false)
                guard endCaptureAttempt(generation) else { return }
                present(captures: captures, purpose: .recording)
            } catch {
                guard generation == captureGeneration else { return }
                fail(error)
            }
        }
    }

    func startRecordScreen(formatOverride: RecordingFormat? = nil) {
        pendingRecordingFormatOverride = formatOverride
        guard !isCapturing, ensurePermission() else { return }
        let layout = ScreenLayout.current()
        guard let screen = layout.screen(containingAppKitPoint: NSEvent.mouseLocation) else {
            fail(CaptureError.screenNotFound)
            return
        }
        beginRecording(
            displayID: screen.displayID,
            rect: CGRect(origin: .zero, size: screen.frame.size),
            backingScale: screen.backingScale,
            metadata: CaptureMetadata(
                source: .fullScreen,
                appName: frontmostAppName,
                windowTitle: nil
            )
        )
    }

    private func beginRecording(
        displayID: CGDirectDisplayID,
        rect: CGRect,
        backingScale: CGFloat,
        metadata: CaptureMetadata
    ) {
        dismiss()
        captureWatchdog?.cancel()
        captureWatchdog = nil
        guard !recordingInProgress else { return }

        let settings = self.settings
        let format = pendingRecordingFormatOverride ?? settings.recordingFormat
        pendingRecordingFormatOverride = nil
        let directory = URL(fileURLWithPath: settings.saveDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            fail(error)
            return
        }
        let name = CaptureFileSaver.defaultRecordingFileName(
            format: format,
            template: settings.fileNameTemplate,
            metadata: metadata
        )
        let url = ImageFileNaming.uniqueURL(in: directory, preferredName: name)

        let control = RecordingControlController(
            format: format,
            onStop: { [weak self] in self?.stopRecording() },
            onCancel: { [weak self] in self?.cancelRecording() }
        )
        let session = ScreenRecordingSession(
            displayID: displayID,
            rect: rect,
            backingScale: backingScale,
            fps: settings.recordingFPS,
            format: format,
            maxSeconds: settings.recordingMaxSeconds,
            gifMaxWidth: settings.recordingGIFMaxWidth,
            outputURL: url,
            showsCursor: settings.captureCursor,
            onAutomaticFinish: { [weak self] result in
                self?.finishRecording(result)
            }
        )
        recordingSession = session
        recordingControl = control
        recordingOutputURL = url
        recordingInProgress = true
        isCapturing = true
        control.show()
        Task { [weak self] in
            do {
                try await session.start()
            } catch {
                self?.finishRecording(.failure(error))
            }
        }
    }

    /// URL/CLI entry points for stopping an active recording.
    func stopRecordingForAutomation() {
        stopRecording()
    }

    func cancelRecordingForAutomation() {
        cancelRecording()
    }

    private func stopRecording() {
        guard recordingInProgress, let session = recordingSession else { return }
        Task { [weak self] in
            let result = await session.stop()
            self?.finishRecording(result)
        }
    }

    private func cancelRecording() {
        guard recordingInProgress, let session = recordingSession else { return }
        Task { [weak self] in
            await session.cancel()
            self?.finishRecording(.failure(CancellationError()))
        }
    }

    private func finishRecording(_ result: Result<URL, Error>) {
        guard recordingInProgress else { return }
        recordingInProgress = false
        isCapturing = false
        recordingControl?.close()
        recordingControl = nil
        recordingSession = nil
        let pendingURL = recordingOutputURL
        recordingOutputURL = nil

        switch result {
        case .success(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .failure(let error):
            if let pendingURL {
                try? FileManager.default.removeItem(at: pendingURL)
            }
            guard !(error is CancellationError) else { return }
            NSAlert(error: error).runModal()
        }
    }

    func startWindowCapture(mode: String = "window") {
        deliveryMode = mode
        guard beginCapture() else { return }
        let generation = captureGeneration
        Task {
            do {
                let targets = try await captureService.windowInventory()
                guard endCaptureAttempt(generation) else { return }
                presentWindowPicker(targets)
            } catch {
                guard generation == captureGeneration else { return }
                fail(error)
            }
        }
    }

    /// Captures every on-screen window of the app that was active before the
    /// capture UI came forward, composited in window-server order.
    func startAppWindowsCapture(appName explicitName: String? = nil) {
        deliveryMode = "window"
        guard beginCapture() else { return }
        let appName = explicitName
            ?? frontmostAppName
            ?? NSWorkspace.shared.frontmostApplication?.localizedName
        guard let appName, !appName.isEmpty else {
            fail(CaptureError.noApplicationWindows("?"))
            return
        }
        let generation = captureGeneration
        Task {
            do {
                let capture = try await captureService.captureApplicationWindows(
                    appName: appName,
                    includeCursor: settings.captureCursor
                )
                guard endCaptureAttempt(generation) else { return }
                isCapturing = false
                deliver(
                    capture.image,
                    source: .window,
                    backingScale: capture.geometry.backingScale,
                    metadata: CaptureMetadata(
                        source: .window,
                        appName: appName,
                        windowTitle: nil
                    )
                )
            } catch {
                guard generation == captureGeneration else { return }
                fail(error)
            }
        }
    }

    /// Captures the display under the pointer.
    func startScreenCapture(mode: String = "screen") {
        deliveryMode = mode
        guard beginCapture() else { return }
        let generation = captureGeneration
        let layout = ScreenLayout.current()
        guard let screen = layout.screen(containingAppKitPoint: NSEvent.mouseLocation) else {
            fail(CaptureError.screenNotFound)
            return
        }
        Task {
            do {
                let capture = try await captureService.captureDisplay(
                    displayID: screen.displayID,
                    includeCursor: settings.captureCursor
                )
                guard endCaptureAttempt(generation) else { return }
                isCapturing = false
                deliver(capture.image, source: .fullScreen, backingScale: capture.geometry.backingScale)
            } catch {
                guard generation == captureGeneration else { return }
                fail(error)
            }
        }
    }

    /// Captures every display and composes them in their physical arrangement.
    func startAllScreensCapture() {
        deliveryMode = "allScreens"
        guard beginCapture() else { return }
        let generation = captureGeneration
        Task {
            do {
                let captures = try await captureService.captureAllDisplays(
                    includeCursor: settings.captureCursor
                )
                let image: CGImage
                var composedScale = captures.first?.geometry.backingScale ?? 1
                if captures.count == 1 {
                    image = captures[0].image
                } else {
                    let slices = captures.map {
                        ScreenSlice(
                            image: $0.image,
                            frame: $0.geometry.frame,
                            backingScale: $0.geometry.backingScale
                        )
                    }
                    // Composition touches every output pixel; keep it off the
                    // main actor so a large multi-display capture does not
                    // freeze the menu or editor. ScreenComposition is the
                    // Sendable wrapper for the resulting CGImage and the
                    // scale actually used (which may be budget-limited).
                    let composed = await Task.detached(priority: .userInitiated) {
                        ScreenComposer.composeWithScale(slices)
                    }.value
                    guard let composed else {
                        throw CaptureError.compositionFailed
                    }
                    image = composed.image
                    composedScale = composed.scale
                }
                guard endCaptureAttempt(generation) else { return }
                isCapturing = false
                deliver(image, source: .fullScreen, backingScale: composedScale)
            } catch {
                guard generation == captureGeneration else { return }
                fail(error)
            }
        }
    }

    func startTimedRegionCapture() {
        deliveryMode = "timedRegion"
        startTimedCapture { [weak self] in
            self?.startRegionCapture(mode: "timedRegion")
        }
    }

    func startTimedScreenCapture() {
        deliveryMode = "timedScreen"
        startTimedCapture { [weak self] in
            self?.startScreenCapture(mode: "timedScreen")
        }
    }

    func startTimedWindowCapture() {
        deliveryMode = "timedWindow"
        startTimedCapture { [weak self] in
            self?.startWindowCapture(mode: "timedWindow")
        }
    }

    /// Runs `action` after the configured countdown. The countdown lives inside
    /// the coordinator's capture state so no second capture can start while it
    /// is visible.
    private func startTimedCapture(_ action: @escaping () -> Void) {
        guard !isCapturing, ensurePermission() else { return }
        let seconds = settings.captureDelaySeconds
        guard seconds > 0 else {
            action()
            return
        }
        isCapturing = true
        let controller = CountdownController(
            seconds: seconds,
            onFinished: { [weak self] in
                self?.countdownController = nil
                self?.isCapturing = false
                action()
            },
            onCancel: { [weak self] in
                self?.countdownController = nil
                self?.isCapturing = false
            }
        )
        countdownController = controller
        controller.start()
    }

    func startLastRegionCapture() {
        deliveryMode = "lastRegion"
        guard !isCapturing else { return }
        guard let region = lastRegion.load() else {
            showLastRegionUnavailable(
                message: L10n.tr("No previous region has been saved yet. Capture a region first.", "还没有保存过区域，请先进行一次区域截图。")
            )
            return
        }
        startStoredRegionCapture(region, clearOnInvalid: true)
    }

    /// Captures a named preset from the status menu. The preset stays in the
    /// menu even if the layout changed so the user can delete or replace it.
    func startPresetRegionCapture(_ preset: NamedRegion) {
        pendingActionsOverride = nil
        deliveryMode = "lastRegion"
        guard !isCapturing else { return }
        startStoredRegionCapture(preset.region, clearOnInvalid: false)
    }

    private func startStoredRegionCapture(
        _ region: LastRegion,
        clearOnInvalid: Bool
    ) {
        let layout = ScreenLayout.current()
        guard let screen = layout.screens.first(where: { $0.displayID == region.displayID }),
              region.isValid(for: screen.geometry) else {
            if clearOnInvalid {
                lastRegion.clear()
                showLastRegionUnavailable(
                    message: L10n.tr("The previous region is no longer valid because the display layout changed. Capture a new region first.", "显示器布局已变化，上次的区域不再有效，请重新进行区域截图。")
                )
            } else {
                showLastRegionUnavailable(
                    message: L10n.tr("This preset no longer matches the display layout. Save it again after selecting a new region.", "该预设与当前显示器布局不匹配，请重新框选并保存预设。")
                )
            }
            return
        }

        guard beginCapture() else { return }
        let generation = captureGeneration
        Task {
            do {
                let capture = try await captureService.captureDisplay(
                    displayID: screen.displayID,
                    includeCursor: settings.captureCursor
                )
                guard endCaptureAttempt(generation) else { return }
                isCapturing = false
                guard let cropped = capture.cropped(toLocalPoints: region.rect) else {
                    showLastRegionUnavailable(
                        message: L10n.tr("The stored region could not be captured. Capture a new region first.", "保存的区域截取失败，请重新进行区域截图。")
                    )
                    return
                }
                deliver(cropped, source: .region, backingScale: screen.geometry.backingScale)
            } catch {
                guard generation == captureGeneration else { return }
                fail(error)
            }
        }
    }

    /// The status menu stays enabled whenever a region is stored, even if the
    /// layout changed, so clicking it can explain why the region is no longer
    /// usable and clear it. It is disabled only when nothing is stored.
    func canCaptureLastRegion() -> Bool {
        lastRegion.load() != nil
    }

    private func showLastRegionUnavailable(message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.tr("No usable previous region", "没有可用的上次区域")
        alert.informativeText = message
        alert.runModal()
    }

    private func beginScrolling(
        capture: CapturedImage,
        rect: CGRect,
        axis: ScrollAxis,
        autoScroll: Bool
    ) {
        guard rect.width >= 8, rect.height >= 8 else {
            dismiss()
            NSSound.beep()
            return
        }
        dismiss()
        isCapturing = true
        scrollingInProgress = true
        scrollingBackingScale = capture.geometry.backingScale
        let maxHeight = settings.scrollMaxHeight

        let layout = ScreenLayout.current()
        let autoScrollPoint: CGPoint?
        if autoScroll,
           let screen = layout.screens.first(where: {
               $0.displayID == capture.geometry.displayID
           }) {
            let cgRect = layout.cgRect(fromLocalRect: rect, on: screen)
            autoScrollPoint = CGPoint(x: cgRect.midX, y: cgRect.midY)
        } else {
            autoScrollPoint = nil
        }

        let control = ScrollingControlController(
            autoScroll: autoScroll,
            onStop: { [weak self] in self?.stopScrolling() },
            onCancel: { [weak self] in self?.cancelScrolling() }
        )
        let session = ScrollingCaptureSession(
            displayID: capture.geometry.displayID,
            rect: rect,
            backingScale: capture.geometry.backingScale,
            maxHeight: maxHeight,
            fps: settings.scrollCaptureFPS,
            axis: axis,
            autoScroll: autoScroll,
            autoScrollPoint: autoScrollPoint,
            onProgress: { [weak self] height in
                self?.scrollingControl?.update(height: height)
            },
            onAutomaticFinish: { [weak self] result in
                self?.finishScrolling(result)
            }
        )
        scrollingControl = control
        scrollingSession = session
        control.show()

        Task {
            do {
                try await session.start()
                guard scrollingInProgress else {
                    // Cancel/Esc won while the stream was starting.
                    await session.cancel()
                    return
                }
            } catch {
                guard scrollingInProgress else { return }
                cancelScrolling()
                fail(error)
            }
        }
    }

    private func stopScrolling() {
        guard scrollingInProgress, let session = scrollingSession else { return }
        Task {
            let result = await session.stop()
            guard scrollingInProgress else { return }
            if let result {
                finishScrolling(.success(result))
            } else {
                scrollingInProgress = false
                scrollingSession = nil
                scrollingControl?.close()
                scrollingControl = nil
                isCapturing = false
                NSSound.beep()
                presentScrollingMessage(
                    title: L10n.tr("No frames captured", "未捕获到任何画面"),
                    message: L10n.tr(
                        "The capture stream produced no frames. Check Screen Recording permission and try again.",
                        "截图流没有产生任何画面。请检查屏幕录制权限后重试。"
                    )
                )
            }
        }
    }

    private func cancelScrolling() {
        guard scrollingInProgress else { return }
        scrollingInProgress = false
        let session = scrollingSession
        scrollingSession = nil
        scrollingControl?.close()
        scrollingControl = nil
        isCapturing = false
        Task { await session?.cancel() }
    }

    private func finishScrolling(_ result: Result<ScrollingCaptureResult, Error>) {
        guard scrollingInProgress else { return }
        scrollingInProgress = false
        scrollingSession = nil
        scrollingControl?.close()
        scrollingControl = nil
        isCapturing = false

        switch result {
        case .failure(let error):
            fail(error)
        case .success(let capture):
            if capture.reason == .noMovement {
                NSSound.beep()
                presentScrollingMessage(
                    title: L10n.tr("No scrolling detected", "未检测到滚动"),
                    message: L10n.tr("Scroll the content while the capture is running, then press Stop.", "请在截图进行中滚动内容，然后按停止。")
                )
                return
            }
            deliver(capture.image, source: .scrolling, backingScale: scrollingBackingScale)
            switch capture.reason {
            case .limitReached:
                presentScrollingMessage(
                    title: L10n.tr("Scrolling capture truncated", "滚动截图已截断"),
                    message: L10n.tr("The stitched image reached the maximum supported height.", "拼接图像已达到最大支持高度。")
                )
            case .lowConfidence:
                presentScrollingMessage(
                    title: L10n.tr("Scrolling alignment lost", "滚动对齐丢失"),
                    message: L10n.tr("The stitched image contains the content captured before alignment became unreliable.", "已保留对齐失效前捕获的内容。")
                )
            case .stopped, .noMovement:
                break
            }
        }
    }

    private func presentScrollingMessage(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func beginCapture() -> Bool {
        guard !isCapturing else {
            NSSound.beep()
            return false
        }
        guard ensurePermission() else { return false }
        isCapturing = true
        captureGeneration += 1
        armCaptureWatchdog()
        return true
    }

    private func armCaptureWatchdog() {
        captureWatchdog?.cancel()
        let generation = captureGeneration
        captureWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.captureGeneration == generation, self.isCapturing else { return }
            self.fail(CaptureError.timedOut)
        }
    }

    /// Called when the screen-capture request returns. Returns false when a
    /// timeout already invalidated this attempt, so a late result is discarded.
    private func endCaptureAttempt(_ generation: Int) -> Bool {
        guard generation == captureGeneration, isCapturing else { return false }
        captureWatchdog?.cancel()
        captureWatchdog = nil
        return true
    }

    private var selectionConstraints: SelectionConstraints {
        let fixed: CGSize? = settings.selectionFixedWidth > 0
            && settings.selectionFixedHeight > 0
            ? CGSize(
                width: settings.selectionFixedWidth,
                height: settings.selectionFixedHeight
            )
            : nil
        return SelectionConstraints(
            fixedSize: fixed,
            aspectRatio: fixed == nil ? settings.selectionAspectRatio.ratio : nil,
            snapToWindows: settings.selectionSnapToWindows
        )
    }

    private func present(captures: [CapturedImage], purpose: SelectionPurpose) {
        NSApp.activate(ignoringOtherApps: true)
        let constraints = selectionConstraints
        overlays = captures.map { capture in
            let window = SelectionOverlayWindow(screenFrame: capture.geometry.frame)
            let view = SelectionOverlayView(
                captured: capture,
                constraints: constraints
            )
            view.onConfirm = { [weak self] rect in
                switch purpose {
                case .region:
                    self?.complete(capture: capture, rect: rect)
                case .scrolling(let axis, let autoScroll):
                    self?.beginScrolling(
                        capture: capture,
                        rect: rect,
                        axis: axis,
                        autoScroll: autoScroll
                    )
                case .recording:
                    guard let self else { return }
                    self.beginRecording(
                        displayID: capture.geometry.displayID,
                        rect: rect,
                        backingScale: capture.geometry.backingScale,
                        metadata: CaptureMetadata(
                            source: .region,
                            appName: self.frontmostAppName,
                            windowTitle: nil
                        )
                    )
                }
            }
            view.onCancel = { [weak self] in
                self?.dismiss()
            }
            view.onHover = { [weak self, weak view] in
                self?.activeView = view
            }
            window.contentView = view
            window.makeFirstResponder(view)
            window.orderFrontRegardless()
            return window
        }

        activeView = overlays.first?.contentView as? SelectionOverlayView
        installKeyMonitor()

        if let first = overlays.first {
            first.makeKeyAndOrderFront(nil)
        }
    }

    private func presentWindowPicker(_ targets: [WindowTarget]) {
        let layout = ScreenLayout.current()
        NSApp.activate(ignoringOtherApps: true)
        overlays.removeAll()
        activePicker = nil

        for screen in layout.screens {
            let bounds = CGRect(origin: .zero, size: screen.frame.size)
            let screenTargets: [WindowPickerView.Target] = targets.compactMap { target in
                let rect = layout.localRect(fromCGRect: target.frame, on: screen)
                guard rect.intersects(bounds) else { return nil }
                return WindowPickerView.Target(window: target, rect: rect)
            }
            // Cover every screen, even one with no targets, so clicks cannot
            // reach the desktop while the picker is active.
            let window = SelectionOverlayWindow(screenFrame: screen.frame)
            let view = WindowPickerView(screenFrame: screen.frame, targets: screenTargets)
            view.onPick = { [weak self] target in
                self?.capture(window: target)
            }
            view.onCancel = { [weak self] in
                self?.dismiss()
            }
            window.contentView = view
            window.makeFirstResponder(view)
            window.orderFrontRegardless()
            overlays.append(window)
            if activePicker == nil {
                activePicker = view
            }
        }

        guard !overlays.isEmpty else {
            fail(CaptureError.noWindows)
            return
        }
        installKeyMonitor()
        overlays.first?.makeKeyAndOrderFront(nil)
    }

    private func installKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if let active = self.activeView {
                return active.handleKey(event) ? nil : event
            }
            if let picker = self.activePicker {
                return picker.handleKey(event) ? nil : event
            }
            return event
        }
    }

    private func capture(window target: WindowTarget) {
        dismiss()
        guard beginCapture() else { return }
        let generation = captureGeneration
        Task {
            do {
                let capture = try await captureService.captureWindow(
                    windowID: target.windowID,
                    includeCursor: settings.captureCursor
                )
                guard endCaptureAttempt(generation) else { return }
                isCapturing = false
                // Window capture already ignores the window shadow
                // (`ignoreShadowsSingleWindow`), so there is no shadow padding
                // to trim afterwards.
                deliver(
                    capture.image,
                    source: .window,
                    backingScale: capture.geometry.backingScale,
                    metadata: CaptureMetadata(
                        source: .window,
                        appName: target.applicationName,
                        windowTitle: target.title
                    )
                )
            } catch {
                guard generation == captureGeneration else { return }
                fail(error)
            }
        }
    }

    /// Completes a confirmed selection. Internal so the committed harness can
    /// drive the editor and direct-copy paths without a real screen capture.
    func complete(capture: CapturedImage, rect: CGRect) {
        guard let cropped = capture.cropped(toLocalPoints: rect) else {
            dismiss()
            NSSound.beep()
            return
        }
        let region = LastRegion(
            displayID: capture.geometry.displayID,
            rect: rect,
            screenFrame: capture.geometry.frame,
            backingScale: capture.geometry.backingScale
        )
        if region.isValid(for: capture.geometry) {
            lastRegion.save(region)
        }
        dismiss()
        deliver(cropped, source: .region, backingScale: capture.geometry.backingScale)
    }

    /// Opens the editor or copies directly according to the live setting. The
    /// delivery path is shared by every capture mode so history sources and
    /// failure handling cannot drift.
    private func deliver(
        _ image: CGImage,
        source: CaptureSource,
        backingScale: CGFloat = 1,
        metadata: CaptureMetadata? = nil
    ) {
        // Snapshot at delivery time: an encoding pass can outlive a settings
        // change, and all outputs of one capture should agree. The mode is
        // snapshotted too because a second capture may start while this one is
        // still encoding.
        let settings = self.settings
        let actions = pendingActionsOverride ?? settings.actions(for: deliveryMode)
        pendingActionsOverride = nil
        let payload = ImageData(image)
        let history = self.history
        let pasteboard = self.pasteboardProvider()
        let metadata = metadata ?? CaptureMetadata(
            source: source,
            appName: frontmostAppName,
            windowTitle: nil
        )

        Task { [weak self] in
            guard let self else { return }
            let processed = await Task.detached(priority: .userInitiated) { () -> ImageData in
                guard settings.retinaDownscale, backingScale > 1 else { return payload }
                return ImageData(ImageExporter.downscaled(payload.cgImage, by: 1 / backingScale))
            }.value
            let effectiveScale: CGFloat = settings.retinaDownscale && backingScale > 1
                ? 1
                : backingScale

            // Shottr-style: every capture lands in history as soon as it is
            // delivered — saving or copying is optional, and the editor's later
            // copy/save must not duplicate the entry.
            let recordTask = HistoryRecorder.record(
                processed.cgImage,
                source: source,
                settings: settings,
                history: history
            )

            if actions.openEditor {
                let identifier = UUID()
                let editor = EditorWindowController(
                    document: EditDocument(
                        image: processed.cgImage,
                        backingScale: effectiveScale
                    ),
                    settingsProvider: { [weak self] in self?.settings ?? .default },
                    history: history,
                    identifier: identifier,
                    metadata: metadata,
                    pasteboard: pasteboard,
                    onClose: { [weak self] in
                        // Remove only the editor whose close callback runs; a
                        // late close must not drop a newer editor.
                        guard let self else { return }
                        self.editors.removeAll { $0.identifier == identifier }
                    }
                )
                self.editors.append(editor)
                editor.show()
                // Attach the editor to the history entry once the background
                // write completes, so crop/annotations can be saved with it.
                Task { [weak editor] in
                    if let entry = await recordTask.value {
                        editor?.attachHistoryEntry(entry.id)
                    }
                }
                return
            }

            // Direct path: pin/copy/save per the mode's actions. Normalization
            // guarantees one action, but keep a fallback so a stale settings
            // snapshot can never discard the capture silently.
            var shouldCopy = actions.copy
            let shouldSave = actions.save
            let shouldPin = actions.pin
            if !shouldCopy && !shouldSave && !shouldPin { shouldCopy = true }

            // Watermark/beautify only affect copy and save; skip the extra
            // render entirely for pin-only captures.
            var exportImage = processed.cgImage
            let appearance = settings.exportAppearance
            if (shouldCopy || shouldSave), appearance.hasWork {
                exportImage = await Task.detached(priority: .userInitiated) {
                    ExportRenderer.apply(processed.cgImage, options: appearance)
                        ?? processed.cgImage
                }.value
            }
            if shouldPin {
                PinBoard.shared.pin(processed.cgImage)
            }
            if shouldCopy {
                let data = await Task.detached(priority: .userInitiated) {
                    ImageExporter.pngData(from: exportImage)
                }.value
                if let data, PasteboardWriter.writePNG(data, to: pasteboard) {
                    // Copied successfully.
                } else {
                    self.logger.error("Failed to copy the captured screenshot to the pasteboard")
                    NSSound.beep()
                }
            }
            if shouldSave {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try CaptureFileSaver.write(
                            exportImage,
                            format: settings.format,
                            quality: settings.jpegQuality,
                            directory: settings.saveDirectory,
                            targetBytes: settings.targetFileSizeKB > 0
                                ? settings.targetFileSizeKB * 1024
                                : nil,
                            template: settings.fileNameTemplate,
                            metadata: metadata
                        )
                    }.value
                } catch {
                    self.logger.error(
                        "Failed to save the captured screenshot: \(error.localizedDescription)"
                    )
                    NSSound.beep()
                }
            }
        }
    }

    private func fail(_ error: Error) {
        pendingActionsOverride = nil
        captureWatchdog?.cancel()
        captureWatchdog = nil
        dismiss()
        NSAlert(error: error).runModal()
    }

    /// Cancels whichever capture phase is active (countdown, selection
    /// overlay, window picker, scrolling, or an in-flight capture request) so
    /// a normal-level settings window is not hidden behind the overlay.
    func cancelActiveCapture() {
        if recordingInProgress {
            cancelRecording()
        }
        pendingActionsOverride = nil
        countdownController?.cancel()
        countdownController = nil
        cancelScrolling()
        dismiss()
    }

    private func dismiss() {
        captureWatchdog?.cancel()
        captureWatchdog = nil
        captureGeneration += 1
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        activeView = nil
        activePicker = nil
        isCapturing = false
    }

    private func ensurePermission() -> Bool {
        PermissionService.ensureScreenCaptureAccess()
    }
}
