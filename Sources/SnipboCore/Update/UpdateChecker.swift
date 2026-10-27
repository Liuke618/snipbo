import Foundation

/// 向 GitHub Releases 查询最新版本。仅 GET,仅访问 releases/latest。
public struct UpdateChecker: Sendable {
    public static let defaultReleasesURL = URL(
        string: "https://api.github.com/repos/Liuke618/snipbo/releases/latest"
    )!

    private let session: URLSession
    private let releasesURL: URL

    public init(session: URLSession = .shared, releasesURL: URL = UpdateChecker.defaultReleasesURL) {
        self.session = session
        self.releasesURL = releasesURL
    }

    private struct GitHubAssetDTO: Decodable {
        let name: String
        let browser_download_url: URL
        let size: Int
    }

    private struct GitHubReleaseDTO: Decodable {
        let tag_name: String
        let name: String?
        let body: String?
        let assets: [GitHubAssetDTO]
    }

    /// 拉取并解码最新 release。状态映射顺序固定:速率限制头优先于 403/404。
    public func check() async throws -> UpdateRelease {
        var request = URLRequest(url: releasesURL)
        request.timeoutInterval = 15
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateError.requestFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.requestFailed("no HTTP response")
        }
        let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining")
        if (http.statusCode == 403 || http.statusCode == 429), remaining == "0" {
            throw UpdateError.rateLimited
        }
        switch http.statusCode {
        case 200:
            break
        case 403, 404:
            throw UpdateError.channelUnavailable
        case let status:
            throw UpdateError.requestFailed("HTTP \(status)")
        }
        let dto = try JSONDecoder().decode(GitHubReleaseDTO.self, from: data)
        return UpdateRelease(
            tagName: dto.tag_name,
            displayName: dto.name ?? dto.tag_name,
            notes: dto.body ?? "",
            assets: dto.assets.map {
                UpdateAsset(name: $0.name, url: $0.browser_download_url, size: $0.size)
            }
        )
    }
}
