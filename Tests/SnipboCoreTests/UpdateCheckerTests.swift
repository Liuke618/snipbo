import Foundation
import Testing
@testable import SnipboCore

// .serialized: the tests share the global StubURLProtocol.handler, so they
// must not run in parallel with each other.
@Suite("UpdateCheckerTests", .serialized)
struct UpdateCheckerTests {
    private func makeChecker() -> UpdateChecker {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return UpdateChecker(session: URLSession(configuration: config))
    }

    private let fixture = """
    {
      "tag_name": "v0.6.0",
      "name": "Snipbo 0.6.0",
      "body": "## Highlights\\n- updater",
      "assets": [
        {"name": "Snipbo-0.6.0-arm64.zip",
         "browser_download_url": "https://github.com/Liuke618/snipbo/releases/download/v0.6.0/Snipbo-0.6.0-arm64.zip",
         "size": 12345},
        {"name": "Snipbo-0.6.0-arm64.zip.sha256",
         "browser_download_url": "https://github.com/Liuke618/snipbo/releases/download/v0.6.0/Snipbo-0.6.0-arm64.zip.sha256",
         "size": 95}
      ]
    }
    """.data(using: .utf8)!

    @Test func decodesLatestRelease() async throws {
        StubURLProtocol.handler = { _ in (200, [:], fixture) }
        defer { StubURLProtocol.handler = nil }
        let release = try await makeChecker().check()
        #expect(release.tagName == "v0.6.0")
        #expect(release.assets.count == 2)
        #expect(release.assets[0].size == 12_345)
    }

    @Test func privateChannelMapsToChannelUnavailable() async {
        StubURLProtocol.handler = { _ in (404, [:], Data()) }
        defer { StubURLProtocol.handler = nil }
        do {
            _ = try await makeChecker().check()
            Issue.record("expected channelUnavailable")
        } catch {
            #expect(error as? UpdateError == .channelUnavailable)
        }
    }

    @Test func rateLimitHeadersMapToRateLimited() async {
        StubURLProtocol.handler = { _ in
            (403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1735000000"], Data())
        }
        defer { StubURLProtocol.handler = nil }
        do {
            _ = try await makeChecker().check()
            Issue.record("expected rateLimited")
        } catch {
            #expect(error as? UpdateError == .rateLimited)
        }
    }

    @Test func otherStatusMapsToRequestFailed() async {
        StubURLProtocol.handler = { _ in (500, [:], Data()) }
        defer { StubURLProtocol.handler = nil }
        do {
            _ = try await makeChecker().check()
            Issue.record("expected requestFailed")
        } catch {
            if case .requestFailed = error as? UpdateError {
                // 通过
            } else {
                Issue.record("expected requestFailed, got \(error)")
            }
        }
    }
}
