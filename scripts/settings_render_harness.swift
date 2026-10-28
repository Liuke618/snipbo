import AppKit
import Foundation
import SnipboCore
import SwiftUI

// Settings render harness: hosts the real SettingsView in a displayed window and
// writes PNGs, so layout claims can be measured instead of eyeballed from a
// cropped screenshot.
//
//   .build/settings-render [outdir] [tab-raw-value] [idle] [card]
//
// ImageRenderer is not used for the panes: it drops ScrollView content (the
// release-notes card included), so capture goes through a real window. `idle`
// skips driving UpdateCoordinator into the .available state; `card` renders the
// notes card alone.

@MainActor
func spin(_ seconds: Double) async {
    // Suspending the main actor lets the harness's runloop pump service the
    // coordinator's background Task; RunLoop.run is unavailable async.
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

/// Serves a canned GitHub release so the coordinator can be driven into the
/// `.available` state without touching the network.
final class ReleaseStubProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
func driveIntoAvailableState() async {
    let json = """
    {
      "tag_name": "v0.7.0",
      "name": "0.7.0",
      "body": "## What is new\\n\\n- Scroll capture now stitches long pages with a live height readout.\\n- The editor gained a polygon tool, measure arrows and a floating style panel.\\n- AVIF and HEIC export, with a quality slider that survives relaunch.\\n- Fixed: the pin window lost its shadow on a secondary display.\\n\\nSee the release page for the full list of 24 changes.",
      "assets": [
        {
          "name": "Snipbo-0.7.0-arm64.zip",
          "browser_download_url": "https://example.invalid/Snipbo-0.7.0-arm64.zip",
          "size": 4210000
        },
        {
          "name": "Snipbo-0.7.0-arm64.zip.sha256",
          "browser_download_url": "https://example.invalid/Snipbo-0.7.0-arm64.zip.sha256",
          "size": 96
        }
      ]
    }
    """
    ReleaseStubProtocol.body = Data(json.utf8)
    URLProtocol.registerClass(ReleaseStubProtocol.self)
    UpdateCoordinator.shared.checkInteractively()
    // The check hops through a background Task; wait for it to publish.
    for _ in 0..<40 {
        await spin(0.05)
        if case .available = UpdateCoordinator.shared.state { return }
    }
    print("warning: coordinator never reached .available")
}

@main
struct SettingsRenderHarness {
    static func main() {
        _ = NSApplication.shared
        // The app pins itself to darkAqua (AppDelegate.applyAppearance); mirror it.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await run()
            done.signal()
        }
        while done.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        exit(0)
    }

    @MainActor
    static func run() async {
        let dir = URL(
            fileURLWithPath: CommandLine.arguments.count > 1
                ? CommandLine.arguments[1] : "/tmp/snipbo-settings"
        )
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wanted = CommandLine.arguments.first(where: {
            SettingsTab.allCases.map(\.rawValue).contains($0)
        })
        let tabs: [SettingsTab] = wanted.flatMap { raw in
            SettingsTab(rawValue: raw).map { [$0] }
        } ?? [.updates, .general]

        // A private suite keeps the harness from rewriting the real settings.
        let defaults = UserDefaults(suiteName: "local.snipbo.render") ?? .standard
        if CommandLine.arguments.contains("card") {
            // Isolates the notes card: ImageRenderer is known to be unreliable
            // around ScrollView, so this separates "card is broken" from
            // "renderer cannot draw a scroll view".
            let sample = """
            ## What is new

            - Scroll capture stitches long pages with a live height readout.
            - The editor gained a polygon tool and a **floating style panel**.

            See the release page for the full list.
            """
            render(
                ReleaseNotesCard(notes: sample).frame(width: 320),
                named: "card",
                to: dir
            )
            // Control: does ImageRenderer draw a bare ScrollView at all?
            render(
                ScrollView { Text("scrollview control").font(.system(size: 20)) }
                    .frame(width: 320, height: 80)
                    .background(Color.white),
                named: "scroll-control",
                to: dir
            )
            // ImageRenderer drops ScrollView content, so the card needs a real
            // displayed window to be captured faithfully.
            await renderInWindow(
                ReleaseNotesCard(notes: sample).frame(width: 320),
                named: "card-window",
                size: NSSize(width: 320, height: 210),
                to: dir
            )
            return
        }
        for tab in tabs {
            // The updates pane reads UpdateCoordinator.shared, so its default
            // pass needs the coordinator driven into .available first; `idle`
            // renders the untouched state.
            let idle = CommandLine.arguments.contains("idle")
            if tab == .updates && !idle {
                await driveIntoAvailableState()
                print("updates state: \(UpdateCoordinator.shared.state)")
            }
            let selection = SettingsTabSelection()
            selection.tab = tab
            let view = SettingsView(model: SettingsModel(defaults: defaults), tabSelection: selection)
            let suffix = tab == .updates ? (idle ? "-idle" : "-available") : ""
            await renderInWindow(
                view,
                named: "settings-\(tab.rawValue)\(suffix)",
                size: NSSize(width: 560, height: 609),
                to: dir
            )
        }
    }

    /// Captures a view through a real, displayed window: `cacheDisplay` only
    /// gets SwiftUI's text once the window has committed its layers.
    @MainActor
    static func renderInWindow(
        _ view: some View,
        named name: String,
        size: NSSize,
        to dir: URL
    ) async {
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 200, y: 200), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // The window's own background is not part of the content view's
        // drawing, so a bare cacheDisplay captures transparent pixels and the
        // white text lands on nothing. Paint the app's canvas color under the
        // view, which is exactly what the window contributes in the app.
        window.contentView = NSHostingView(
            rootView: view.background(Color(nsColor: DesignTokens.Color.canvasBase))
        )
        window.backgroundColor = DesignTokens.Color.canvasBase
        window.orderFrontRegardless()
        await spin(0.8)
        let url = dir.appendingPathComponent("\(name).png")
        guard let content = window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            print("\(name): no bitmap rep")
            window.close()
            return
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
            print("\(name): wrote \(url.path) size=\(content.bounds.size) (\(data.count) bytes)")
        }
        window.close()
    }

    /// NSHostingView + cacheDisplay drops SwiftUI's text layers, so the
    /// offscreen path here is ImageRenderer.
    @MainActor
    static func render(_ view: some View, named name: String, to dir: URL) {
        let url = dir.appendingPathComponent("\(name).png")
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            print("\(name): renderer produced no image")
            return
        }
        try? data.write(to: url)
        print("\(name): wrote \(url.path) size=\(image.size) (\(data.count) bytes)")
    }
}
