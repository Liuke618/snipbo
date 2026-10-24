import AppKit
import Foundation
import SnipboCore
import ScreenCaptureKit
import CoreGraphics

// Diagnostic harness: renders the Settings window to a PNG (no TCC needed —
// in-process display capture) and times the real capture service so a stall
// or error shows up with a timestamp.

@main
struct DiagHarness {
    static func main() {
        _ = NSApplication.shared
        print("preflight: \(CGPreflightScreenCaptureAccess())")

        renderSettings()

        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await timeCapture()
            done.signal()
        }
        while done.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        print("diag done")
        exit(0)
    }

    @MainActor
    static func renderSettings() {
        let model = SettingsModel(defaults: UserDefaults())
        let controller = SettingsWindowController(model: model)
        controller.show()
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard let window = controller.window, let content = window.contentView else {
            print("settings: no window")
            return
        }
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            print("settings: no bitmap rep")
            return
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let url = URL(fileURLWithPath: "/tmp/snipbo-settings.png")
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        print("settings window: \(Int(window.frame.width))x\(Int(window.frame.height)) → \(url.path)")
        controller.close()
    }

    @MainActor
    static func timeCapture() async {
        let service = ScreenCaptureService()
        let start = Date()
        print("captureAllDisplays: starting…")
        do {
            let result = try await withTimeout(seconds: 10) {
                try await service.captureAllDisplays(includeCursor: false)
            }
            let ms = Int(-start.timeIntervalSinceNow * 1000)
            print("captureAllDisplays: OK in \(ms) ms, \(result.count) display(s)")
        } catch CaptureError.timedOut {
            print("captureAllDisplays: STALLED >10 s (no result, no error)")
        } catch {
            let ms = Int(-start.timeIntervalSinceNow * 1000)
            print("captureAllDisplays: ERROR after \(ms) ms: \(error.localizedDescription)")
        }
    }

    static func withTimeout<T: Sendable>(seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CaptureError.timedOut
            }
            guard let first = try await group.next() else {
                throw CaptureError.timedOut
            }
            group.cancelAll()
            return first
        }
    }
}
