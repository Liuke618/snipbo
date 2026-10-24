import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Darwin
import Foundation
import SnipboCore
import UniformTypeIdentifiers

/// Committed Phase 1 fix-wave harness.
///
/// Exercises the three app-level regressions that the Core tests cannot cover:
/// 1. a second capture retains (and does not disable) the first editor,
/// 2. a direct copy whose pasteboard write fails restores the clipboard and
///    records no history,
/// 3. a rejected hotkey registration reports failure, leaves no stale
///    registration, and can restore the previous hotkey.
///
/// It also checks that an open editor reads live settings and that the Recent
/// menu drops cached entries whose files disappeared.
///
/// Run with `scripts/run_final_fix_harness.sh` (documented in the fix report).
@MainActor
final class FakePasteboard: PasteboardWriting {
    var pasteboardItems: [NSPasteboardItem]?
    var setDataSucceeds = true
    private(set) var setDataCalls = 0
    private(set) var clearCalls = 0
    private(set) var writeObjectsCalls = 0
    private(set) var lastWrittenItems: [NSPasteboardItem] = []
    private(set) var storedData: Data?

    init(initialItems: [NSPasteboardItem] = []) {
        self.pasteboardItems = initialItems
    }

    @discardableResult
    func clearContents() -> Int {
        clearCalls += 1
        pasteboardItems = nil
        return 0
    }

    func setData(_ data: Data?, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        setDataCalls += 1
        guard setDataSucceeds else { return false }
        storedData = data
        let item = NSPasteboardItem()
        if let data {
            item.setData(data, forType: dataType)
        }
        pasteboardItems = [item]
        return true
    }

    @discardableResult
    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool {
        writeObjectsCalls += 1
        lastWrittenItems = objects.compactMap { $0 as? NSPasteboardItem }
        pasteboardItems = lastWrittenItems
        return true
    }
}

@MainActor
final class HarnessReporter {
    private(set) var checks = 0
    private(set) var failures = 0

    func check(_ condition: Bool, _ name: String) {
        checks += 1
        if condition {
            print("PASS  \(name)")
        } else {
            failures += 1
            print("FAIL  \(name)")
        }
    }

    func recordFailure(_ name: String) {
        checks += 1
        failures += 1
        print("FAIL  \(name)")
    }
}

@main
@MainActor
struct FinalFixHarness {
    static func main() async {
        _ = NSApplication.shared
        _ = NSApp.setActivationPolicy(.accessory)

        let reporter = HarnessReporter()
        do {
            try await testEditorRetention(reporter)
            try await testDirectCopy(reporter)
            try await testOptionArrowDirections(reporter)
            try await testRecentMenuCache(reporter)
            testHotkeyRegistration(reporter)
        } catch {
            reporter.recordFailure("harness threw: \(error)")
        }

        print("\(reporter.checks - reporter.failures)/\(reporter.checks) checks passed")
        exit(reporter.failures == 0 ? 0 : 1)
    }

    // MARK: - Two capture editors

    private static func testEditorRetention(_ reporter: HarnessReporter) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)

        var settings = AppSettings.default
        settings.openEditorAfterCapture = true
        settings.historyEnabled = false
        let pasteboard = FakePasteboard()
        let lastRegion = LastRegionStore(
            defaults: UserDefaults(suiteName: "local.snipbo.harness.\(UUID().uuidString)")!
        )
        let coordinator = CaptureCoordinator(
            captureService: ScreenCaptureService(),
            settings: settings,
            history: store,
            lastRegion: lastRegion,
            pasteboardProvider: { pasteboard }
        )
        let capture = try makeCapture()

        coordinator.complete(capture: capture, rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        coordinator.complete(capture: capture, rect: CGRect(x: 0, y: 0, width: 100, height: 100))

        reporter.check(
            coordinator.editors.count == 2,
            "a second capture retains both capture editors"
        )
        guard coordinator.editors.count == 2 else { return }
        let first = coordinator.editors[0]
        let second = coordinator.editors[1]
        reporter.check(first !== second, "capture editors are distinct instances")

        // Delivery-time history (Shottr-style): captures delivered while
        // history is disabled record nothing.
        reporter.check(
            await store.entries().isEmpty,
            "captures delivered with history off record nothing"
        )

        // Enabling history applies from the next delivery onward.
        settings.historyEnabled = true
        coordinator.updateSettings(settings)
        reporter.check(
            first.copyToPasteboard(),
            "the first editor still handles actions after the second capture"
        )
        coordinator.complete(capture: capture, rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        let recorded = await waitUntil { await store.entries().count == 1 }
        reporter.check(recorded, "enabling history records the next delivered capture")

        // The editor's own copy/save must not duplicate the delivered entry.
        settings.historyEnabled = false
        coordinator.updateSettings(settings)
        _ = first.copyToPasteboard()
        try await Task.sleep(nanoseconds: 200_000_000)
        reporter.check(
            await store.entries().count == 1,
            "copying with history off adds no second entry"
        )

        // The editor must read settings at action time, not from a snapshot.
        settings.format = .jpeg
        coordinator.updateSettings(settings)
        reporter.check(
            first.savePanel(fileName: "Harness").allowedContentTypes == [.jpeg],
            "an open editor reads the current save format at action time"
        )

        first.close()
        let third = coordinator.editors[1]
        third.close()
        reporter.check(
            coordinator.editors.count == 1 && coordinator.editors[0] === second,
            "closing two editors keeps the last one retained"
        )
        second.close()
        reporter.check(
            coordinator.editors.isEmpty,
            "closing the last editor clears the retained list"
        )
    }

    // MARK: - Direct copy

    private static func testDirectCopy(_ reporter: HarnessReporter) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)

        let prior = NSPasteboardItem()
        prior.setData(Data("previous clipboard".utf8), forType: .string)
        let pasteboard = FakePasteboard(initialItems: [prior])
        pasteboard.setDataSucceeds = false

        var settings = AppSettings.default
        settings.openEditorAfterCapture = false
        settings.historyEnabled = true
        let lastRegion = LastRegionStore(
            defaults: UserDefaults(suiteName: "local.snipbo.harness.\(UUID().uuidString)")!
        )
        let coordinator = CaptureCoordinator(
            captureService: ScreenCaptureService(),
            settings: settings,
            history: store,
            lastRegion: lastRegion,
            pasteboardProvider: { pasteboard }
        )
        let capture = try makeCapture()

        coordinator.complete(capture: capture, rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        reporter.check(pasteboard.setDataCalls == 1, "direct copy attempts the pasteboard write")
        reporter.check(
            pasteboard.writeObjectsCalls == 1
                && pasteboard.lastWrittenItems.first?.data(forType: .string)
                    == Data("previous clipboard".utf8),
            "a failed direct copy restores the previous clipboard contents"
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        // The clipboard write failed, but the capture itself still happened
        // and is recorded (Shottr-style) so it can be re-copied later.
        reporter.check(
            await store.entries().count == 1,
            "a failed direct copy still records the capture"
        )

        pasteboard.setDataSucceeds = true
        coordinator.complete(capture: capture, rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        let recorded = await waitUntil { await store.entries().count == 2 }
        reporter.check(recorded, "the second delivered capture records history too")
    }

    // MARK: - Option+arrow boundary resizing

    private static func testOptionArrowDirections(_ reporter: HarnessReporter) async throws {
        let view = SelectionOverlayView(captured: try makeCapture())
        let initial = CGRect(x: 30, y: 30, width: 40, height: 40)

        func press(_ keyCode: UInt16, shift: Bool = false) -> Bool {
            var flags: NSEvent.ModifierFlags = [.option]
            if shift { flags.insert(.shift) }
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: keyCode
            ) else { return false }
            return view.handleKey(event)
        }

        view.selection = SelectionModel(rect: initial)
        _ = press(123)
        reporter.check(
            view.selection.rect == CGRect(x: 29, y: 30, width: 41, height: 40),
            "Option+Left moves the left edge left"
        )

        view.selection = SelectionModel(rect: initial)
        _ = press(124)
        reporter.check(
            view.selection.rect == CGRect(x: 30, y: 30, width: 41, height: 40),
            "Option+Right moves the right edge right"
        )

        view.selection = SelectionModel(rect: initial)
        _ = press(126)
        reporter.check(
            view.selection.rect == CGRect(x: 30, y: 29, width: 40, height: 41),
            "Option+Up moves the top edge up"
        )

        view.selection = SelectionModel(rect: initial)
        _ = press(125)
        reporter.check(
            view.selection.rect == CGRect(x: 30, y: 30, width: 40, height: 41),
            "Option+Down moves the bottom edge down"
        )

        view.selection = SelectionModel(rect: initial)
        _ = press(123, shift: true)
        reporter.check(
            view.selection.rect == CGRect(x: 20, y: 30, width: 50, height: 40),
            "Shift+Option+Left moves the left edge by 10 points"
        )
    }

    // MARK: - Recent menu cache

    private static func testRecentMenuCache(_ reporter: HarnessReporter) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(baseDirectory: directory, maxItems: 10, maxBytes: 10 * 1024 * 1024)
        let entry = try await store.record(image: ImageData(try makeImage()), source: .region)

        let controller = RecentMenuController(history: store, openEntry: { _ in })
        await controller.refresh()
        let imageURL = await store.imageURL(for: entry)
        try FileManager.default.removeItem(at: imageURL)

        controller.menuWillOpen(controller.menu)
        reporter.check(
            controller.menu.items.count == 1
                && controller.menu.items.first?.title == "No recent screenshots",
            "the Recent menu drops cached entries whose image file disappeared"
        )
        controller.menuDidClose(controller.menu)
    }

    // MARK: - Hotkey registration

    private static func testHotkeyRegistration(_ reporter: HarnessReporter) {
        let previous = Hotkey(keyCode: 26, modifiers: [.command, .shift])
        let rejected = Hotkey(keyCode: 26, modifiers: [.command, .control, .option, .shift])
        let fakeRef = EventHotKeyRef(bitPattern: 0x4C534854)!
        var registrarCalls = 0
        var unregisterCalls = 0

        let service = HotkeyService(
            handler: {},
            registrar: { hotkey, _ in
                registrarCalls += 1
                guard hotkey != rejected else { return (OSStatus(-1), nil) }
                return (noErr, fakeRef)
            },
            unregistrar: { _ in unregisterCalls += 1 }
        )

        reporter.check(service.register(previous), "the previous hotkey registers")
        reporter.check(service.isRegistered, "a successful registration keeps a hotkey reference")
        reporter.check(!service.register(rejected), "a rejected hotkey reports failure")
        reporter.check(!service.isRegistered, "a failed registration clears the hotkey reference")
        reporter.check(service.register(previous), "the previous hotkey can be restored after a failure")
        reporter.check(service.isRegistered, "the restored hotkey is registered")
        service.shutdown()
        reporter.check(!service.isRegistered, "shutdown unregisters the hotkey")

        let uninstalled = HotkeyService(
            handler: {},
            registrar: { _, _ in
                registrarCalls += 1
                return (noErr, fakeRef)
            },
            unregistrar: { _ in unregisterCalls += 1 },
            eventHandlerInstallSucceeded: false
        )
        let callsBefore = registrarCalls
        reporter.check(
            !uninstalled.register(previous),
            "registration fails when the event handler did not install"
        )
        reporter.check(
            registrarCalls == callsBefore,
            "no Carbon registration is attempted without an event handler"
        )
        uninstalled.shutdown()
    }

    // MARK: - Fixtures

    private static func makeCapture() throws -> CapturedImage {
        CapturedImage(
            image: try makeImage(),
            geometry: ScreenGeometry(
                displayID: 1,
                frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                backingScale: 1
            )
        )
    }

    private static func makeImage() throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: 100,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw HarnessError.fixtureFailed
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        guard let image = context.makeImage() else { throw HarnessError.fixtureFailed }
        return image
    }

    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipboHarness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }
}

enum HarnessError: Error {
    case fixtureFailed
}
