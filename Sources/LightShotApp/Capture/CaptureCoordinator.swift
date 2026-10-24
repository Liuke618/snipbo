import AppKit
import LightShotCore
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

    private enum SelectionPurpose {
        case region
        case scrolling
    }

    private var scrollingSession: ScrollingCaptureSession?
    private var scrollingControl: ScrollingControlController?
    private var scrollingInProgress = false
    private var scrollingBackingScale: CGFloat = 1
    /// Every open capture editor, retained until its own close callback runs.
    /// The callback removes exactly the editor that closed, so a second
    /// capture can never deallocate (and disable) the first editor.
    private(set) var editors: [EditorWindowController] = []
    private let logger = Logger(subsystem: "local.lightshot.app", category: "Capture")

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

    func start(_ command: CaptureCommand) {
        switch command {
        case .region:
            startRegionCapture()
        case .window:
            startWindowCapture()
        case .screen:
            startScreenCapture()
        case .allScreens:
            startAllScreensCapture()
        case .timedRegion:
            startTimedRegionCapture()
        case .timedScreen:
            startTimedScreenCapture()
        case .lastRegion:
            startLastRegionCapture()
        case .scrolling:
            startScrollingCapture()
        }
    }

    func startRegionCapture() {
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

    func startScrollingCapture() {
        guard beginCapture() else { return }
        let generation = captureGeneration
        Task {
            do {
                let captures = try await captureService.captureAllDisplays(includeCursor: false)
                guard endCaptureAttempt(generation) else { return }
                present(captures: captures, purpose: .scrolling)
            } catch {
                guard generation == captureGeneration else { return }
                fail(error)
            }
        }
    }

    func startWindowCapture() {
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

    /// Captures the display under the pointer.
    func startScreenCapture() {
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
        guard beginCapture() else { return }
        let generation = captureGeneration
        Task {
            do {
                let captures = try await captureService.captureAllDisplays(
                    includeCursor: settings.captureCursor
                )
                let image: CGImage
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
                    // freeze the menu or editor. ImageData is the Sendable
                    // wrapper for the resulting CGImage.
                    let composed = await Task.detached(priority: .userInitiated) { () -> ImageData? in
                        guard let composed = ScreenComposer.compose(slices) else { return nil }
                        return ImageData(composed)
                    }.value
                    guard let composed else {
                        throw CaptureError.compositionFailed
                    }
                    image = composed.cgImage
                }
                guard endCaptureAttempt(generation) else { return }
                isCapturing = false
                deliver(image, source: .fullScreen, backingScale: captures.first?.geometry.backingScale ?? 1)
            } catch {
                guard generation == captureGeneration else { return }
                fail(error)
            }
        }
    }

    func startTimedRegionCapture() {
        startTimedCapture { [weak self] in
            self?.startRegionCapture()
        }
    }

    func startTimedScreenCapture() {
        startTimedCapture { [weak self] in
            self?.startScreenCapture()
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
        guard !isCapturing else { return }
        guard let region = lastRegion.load() else {
            showLastRegionUnavailable(
                message: "No previous region has been saved yet. Capture a region first."
            )
            return
        }

        let layout = ScreenLayout.current()
        guard let screen = layout.screens.first(where: { $0.displayID == region.displayID }),
              region.isValid(for: screen.geometry) else {
            lastRegion.clear()
            showLastRegionUnavailable(
                message: "The previous region is no longer valid because the display layout changed. Capture a new region first."
            )
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
                        message: "The previous region could not be captured. Capture a new region first."
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
        alert.messageText = "No usable previous region"
        alert.informativeText = message
        alert.runModal()
    }

    private func beginScrolling(capture: CapturedImage, rect: CGRect) {
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

        let control = ScrollingControlController(
            onStop: { [weak self] in self?.stopScrolling() },
            onCancel: { [weak self] in self?.cancelScrolling() }
        )
        let session = ScrollingCaptureSession(
            displayID: capture.geometry.displayID,
            rect: rect,
            backingScale: capture.geometry.backingScale,
            maxHeight: maxHeight,
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
                    title: "No scrolling detected",
                    message: "Scroll the content while the capture is running, then press Stop."
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
                    title: "No scrolling detected",
                    message: "Scroll the content while the capture is running, then press Stop."
                )
                return
            }
            deliver(capture.image, source: .scrolling, backingScale: scrollingBackingScale)
            switch capture.reason {
            case .limitReached:
                presentScrollingMessage(
                    title: "Scrolling capture truncated",
                    message: "The stitched image reached the maximum supported height."
                )
            case .lowConfidence:
                presentScrollingMessage(
                    title: "Scrolling alignment lost",
                    message: "The stitched image contains the content captured before alignment became unreliable."
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

    private func present(captures: [CapturedImage], purpose: SelectionPurpose) {
        NSApp.activate(ignoringOtherApps: true)
        overlays = captures.map { capture in
            let window = SelectionOverlayWindow(screenFrame: capture.geometry.frame)
            let view = SelectionOverlayView(captured: capture)
            view.onConfirm = { [weak self] rect in
                switch purpose {
                case .region:
                    self?.complete(capture: capture, rect: rect)
                case .scrolling:
                    self?.beginScrolling(capture: capture, rect: rect)
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
                deliver(capture.image, source: .window, backingScale: capture.geometry.backingScale)
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
    private func deliver(_ image: CGImage, source: CaptureSource, backingScale: CGFloat = 1) {
        // Optional retina downscale keeps exports at 1x.
        let image = settings.retinaDownscale && backingScale > 1
            ? ImageExporter.downscaled(image, by: 1 / backingScale)
            : image
        if settings.openEditorAfterCapture {
            let identifier = UUID()
            let editor = EditorWindowController(
                document: EditDocument(image: image),
                settingsProvider: { [weak self] in self?.settings ?? .default },
                history: history,
                identifier: identifier,
                pasteboard: pasteboardProvider(),
                onClose: { [weak self] in
                    // Remove only the editor whose close callback runs; a
                    // late close must not drop a newer editor.
                    guard let self else { return }
                    self.editors.removeAll { $0.identifier == identifier }
                }
            )
            editors.append(editor)
            editor.show()
            return
        }

        // Direct path: copy and/or save per settings. Normalization guarantees
        // at least one of the two is enabled when the editor is off.
        do {
            if settings.afterCaptureCopy {
                guard let data = ImageExporter.pngData(from: image) else {
                    NSSound.beep()
                    return
                }
                // Encode before touching the pasteboard, then write with rollback
                // so a rejected write leaves the previous clipboard contents in
                // place and never records a screenshot that was not copied.
                guard PasteboardWriter.writePNG(data, to: pasteboardProvider()) else {
                    logger.error("Failed to copy the captured screenshot to the pasteboard")
                    NSSound.beep()
                    return
                }
            }
            if settings.afterCaptureSave {
                try CaptureFileSaver.write(
                    image,
                    format: settings.format,
                    quality: settings.jpegQuality,
                    directory: settings.saveDirectory
                )
            }
        } catch {
            logger.error("Failed to save the captured screenshot: \(error.localizedDescription)")
            NSSound.beep()
            return
        }
        HistoryRecorder.record(image, source: source, settings: settings, history: history)
    }

    private func fail(_ error: Error) {
        captureWatchdog?.cancel()
        captureWatchdog = nil
        dismiss()
        NSAlert(error: error).runModal()
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
