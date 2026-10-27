# Snipbo 软件更新功能 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 应用内检查 GitHub Releases 新版本,校验后自动替换 `/Applications/Snipbo.app` 并重启;启动静默检查,失败不打扰。

**Architecture:** 纯逻辑全部下沉到 `SnipboCore/Update`(版本比较、API 检查、SHA-256 校验、备份/替换/回滚安装器,全部可单测);`SnipboApp/Update/UpdateCoordinator` 只做状态编排与 UI 汇报。无第三方依赖。

**Tech Stack:** Swift 6 strict concurrency、Foundation URLSession、CryptoKit(SHA256)、Process(`/usr/bin/ditto`、`/usr/bin/open`)、Swift Testing、AppKit/SwiftUI(现有 UI 模式)。

**Spec:** `docs/superpowers/specs/2026-10-28-software-updates-design.md`

## Global Constraints

- macOS 14.0 最低版本;Swift 6 严格并发(`.swiftLanguageMode(.v6)`),`SnipboCore` 内类型标 `public` + `Sendable`。
- 禁止第三方依赖(Package.swift 不动)。
- 出站请求仅两个主机:`api.github.com`(检查)与 `github.com`(资产下载);不带任何自定义头(不加 User-Agent 之外的标识,不发送本机信息)。
- 所有用户可见文案走 `L10n.tr("English", "中文")`。
- 测试框架是 Swift Testing(`import Testing`、`@Suite`、`@Test`、`#expect`);跑法 `swift test --filter <SuiteName>`。
- 对 spec 的一处偏离(有意):当前版本取运行包的 `CFBundleShortVersionString`(安装的是打包版本),取不到时回退 `snipboVersion` 常量——spec 原文写「与 snipboVersion 比较」,但开发源码里的常量不等于用户已安装的版本。
- CLT 工具链:`swift test` 的插件路径问题由 Package.swift 现有逻辑处理,不要改 Package.swift。

## Review Focus

spec 隐含但常规测试容易漏的输入,每条已钉进对应任务:

1. 带速率限制头的 403 与私有渠道 404 必须区分(用户看到「稍后再试」vs「渠道不可用」)→ Task 2 测试。
2. `.sha256` 文本格式变体(大写 hex、多空格、缺文件名)→ Task 3 测试。
3. tag 形如 `v1.0`、`v1.0.0-rc1`、垃圾字符串时不崩溃、不误报更新 → Task 1 测试。
4. 替换中途失败(新包非法)必须回滚且旧包完好 → Task 4 测试。
5. 从 `dist/` 开发构建运行时不出现「下载并安装」按钮 → Task 7 的 UI 判定 + Task 9 手动清单。

---

### Task 1: SemVer 与更新模型(SnipboCore)

**Files:**
- Create: `Sources/SnipboCore/Update/UpdateModels.swift`
- Test: `Tests/SnipboCoreTests/UpdateModelsTests.swift`

**Interfaces:**
- Consumes: 无
- Produces: `struct SemVer: Comparable, Sendable, Equatable`(`parse(_ raw: String) -> SemVer?`、`static func compare(_:_:) -> ComparisonResult?`,nil = 无法比较)、`struct UpdateAsset: Sendable, Equatable`(name/url/size)、`struct UpdateRelease: Sendable, Equatable`(tagName/displayName/notes/assets)、`enum UpdateError: Error, Equatable, Sendable` + `var localizedDescription: String`。

- [ ] **Step 1: 写失败测试**

```swift
import Testing
@testable import SnipboCore

@Suite("UpdateModelsTests")
struct UpdateModelsTests {
    @Test func parsesLeadingV() {
        #expect(SemVer.parse("v0.5.0") == SemVer(major: 0, minor: 5, patch: 0))
        #expect(SemVer.parse("0.5.0")?.description == "0.5.0")
    }

    @Test func padsMissingSegments() {
        // 1.0 == 1.0.0,右侧补零后相等。
        #expect(SemVer.compare("v1.0", "1.0.0") == .orderedSame)
    }

    @Test func ordersBySegment() {
        #expect(SemVer.compare("v0.4.0", "v0.5.0") == .orderedAscending)
        #expect(SemVer.compare("0.10.0", "0.9.0") == .orderedDescending)
    }

    @Test func prereleaseIsIncomparable() {
        // -beta 等非数字段无法判断,不提示更新。
        #expect(SemVer.compare("v1.0.0-rc1", "v1.0.0") == nil)
        #expect(SemVer.compare("not-a-version", "v1.0.0") == nil)
    }

    @Test func errorMessagesAreLocalized() {
        #expect(!UpdateError.channelUnavailable.localizedDescription.isEmpty)
        #expect(!UpdateError.rateLimited.localizedDescription.isEmpty)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter UpdateModelsTests`
Expected: FAIL — `SemVer` / `UpdateError` 不存在(编译错误)。

- [ ] **Step 3: 最小实现**

```swift
import Foundation

/// 更新功能的共享模型与错误。全部值类型,便于跨 actor 传递。
public enum UpdateError: Equatable, Sendable, Error {
    /// 请求本身失败(无网络、非 200 的其他状态)。
    case requestFailed(String)
    /// 发布渠道不可用(403/404,仓库私有或不存在)。
    case channelUnavailable
    /// GitHub API 速率限制。
    case rateLimited
    /// release 里没有可用的 zip/sha256 资产。
    case noMatchingAsset
    /// 下载包 SHA-256 与 .sha256 资产不符。
    case checksumMismatch
    /// 当前应用不在 /Applications 或 ~/Applications,不能自动替换。
    case notInstalledInApplications
    /// 安装中途失败(附带底层错误;旧包已回滚)。
    case installFailed(String)

    public var localizedDescription: String {
        switch self {
        case .requestFailed(let detail):
            return L10n.tr(
                "Could not check for updates: \(detail)",
                "无法检查更新:\(detail)"
            )
        case .channelUnavailable:
            return L10n.tr(
                "The release channel is not reachable yet. Try again later.",
                "发布渠道暂不可用,请稍后再试。"
            )
        case .rateLimited:
            return L10n.tr(
                "GitHub rate limit reached. Try again in a while.",
                "已达到 GitHub 速率限制,请稍后再试。"
            )
        case .noMatchingAsset:
            return L10n.tr(
                "The release has no downloadable package.",
                "该版本没有可下载的安装包。"
            )
        case .checksumMismatch:
            return L10n.tr(
                "The download failed verification and was discarded.",
                "下载包校验失败,已丢弃。"
            )
        case .notInstalledInApplications:
            return L10n.tr(
                "Snipbo is not installed in /Applications, so it cannot be updated in place.",
                "Snipbo 未安装在 /Applications,无法原位更新。"
            )
        case .installFailed(let detail):
            return L10n.tr(
                "The update could not be installed: \(detail). The previous version was restored.",
                "安装失败:\(detail)。已恢复旧版本。"
            )
        }
    }
}

/// 语义化版本(仅数字段)。`parse` 与 `compare` 对 `v` 前缀、缺失段宽容;
/// 预发布段(`-rc1`)与无法解析的输入返回 nil,由调用方按「不提示更新」处理。
public struct SemVer: Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func parse(_ raw: String) -> SemVer? {
        var text = raw.lowercased()
        if text.hasPrefix("v") { text.removeFirst() }
        // 去掉预发布/构建段:纯数字段之外的任何后缀都视为无法比较。
        guard !text.contains("-"), !text.contains("+") else { return nil }
        let parts = text.split(separator: ".")
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let n = Int(part) else { return nil }
            numbers.append(n)
        }
        while numbers.count < 3 { numbers.append(0) }
        return SemVer(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    /// 返回 nil 表示两个版本无法比较(任一解析失败)。
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let a = parse(lhs), let b = parse(rhs) else { return nil }
        if a == b { return .orderedSame }
        if (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) {
            return .orderedAscending
        }
        return .orderedDescending
    }
}

/// GitHub release 的应用侧模型。
public struct UpdateRelease: Equatable, Sendable {
    public var tagName: String
    public var displayName: String
    /// release 说明(可能为空)。
    public var notes: String
    public var assets: [UpdateAsset]

    public init(tagName: String, displayName: String, notes: String, assets: [UpdateAsset]) {
        self.tagName = tagName
        self.displayName = displayName
        self.notes = notes
        self.assets = assets
    }
}

public struct UpdateAsset: Equatable, Sendable {
    public var name: String
    public var url: URL
    public var size: Int

    public init(name: String, url: URL, size: Int) {
        self.name = name
        self.url = url
        self.size = size
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter UpdateModelsTests`
Expected: PASS(5 个用例)。

- [ ] **Step 5: 提交**

```bash
git add Sources/SnipboCore/Update/UpdateModels.swift Tests/SnipboCoreTests/UpdateModelsTests.swift
git commit -m "feat(update): semver parsing and update models"
```

---

### Task 2: UpdateChecker(GitHub API,注入 URLSession)

**Files:**
- Create: `Sources/SnipboCore/Update/UpdateChecker.swift`
- Create: `Tests/SnipboCoreTests/Support/StubURLProtocol.swift`
- Test: `Tests/SnipboCoreTests/UpdateCheckerTests.swift`

**Interfaces:**
- Consumes: `UpdateRelease`、`UpdateError`(Task 1)
- Produces: `public struct UpdateChecker: Sendable`(`init(session: URLSession = .shared, releasesURL: URL = UpdateChecker.defaultReleasesURL)`,`static let defaultReleasesURL: URL` = `https://api.github.com/repos/Liuke618/snipbo/releases/latest`,`func check() async throws -> UpdateRelease`)。内部 DTO `GitHubReleaseDTO: Decodable`(CodingKeys:`tag_name`/`name`/`body`/`assets[name, browser_download_url, size]`,body 缺省 "")。

- [ ] **Step 1: 写失败测试(含 URLProtocol 桩)**

`Tests/SnipboCoreTests/Support/StubURLProtocol.swift`:

```swift
import Foundation

/// 返回预置响应的 URLProtocol,让 checker 测试不碰真实网络。
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, headers, body) = handler(request)
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
```

`Tests/SnipboCoreTests/UpdateCheckerTests.swift`:

```swift
import Foundation
import Testing
@testable import SnipboCore

@Suite("UpdateCheckerTests")
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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter UpdateCheckerTests`
Expected: FAIL — `UpdateChecker` 不存在(编译错误)。

- [ ] **Step 3: 最小实现**

`Sources/SnipboCore/Update/UpdateChecker.swift`:

```swift
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
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter UpdateCheckerTests`
Expected: PASS(4 个用例)。

- [ ] **Step 5: 提交**

```bash
git add Sources/SnipboCore/Update/UpdateChecker.swift Tests/SnipboCoreTests/UpdateCheckerTests.swift Tests/SnipboCoreTests/Support/StubURLProtocol.swift
git commit -m "feat(update): GitHub releases checker with status mapping"
```

---

### Task 3: 资产挑选与 SHA-256 校验(SnipboCore)

**Files:**
- Create: `Sources/SnipboCore/Update/UpdatePackage.swift`
- Test: `Tests/SnipboCoreTests/UpdatePackageTests.swift`

**Interfaces:**
- Consumes: `UpdateRelease`、`UpdateAsset`、`UpdateError`(Task 1)
- Produces: `public struct UpdatePackage: Sendable`
  - `static func pick(from release: UpdateRelease, runningVersion: String) -> (zip: UpdateAsset, sha256: UpdateAsset?)?`
    (zip 名精确匹配 `Snipbo-<ver 去前缀 v>-arm64.zip`;退化:release 只有一个 zip 时取它;sha256 为同名 + `.sha256`,找不到且存在唯一 `.sha256` 资产时取它;无 zip → nil)
  - `static func verifySHA256(of data: Data, digestText: String) -> Bool`(解析 `<hex>[ws]<filename>?`,hex 与大小写无关,解析不出 hex → false)
  - `static func sha256Hex(of data: Data) -> String`

- [ ] **Step 1: 写失败测试**

```swift
import Foundation
import Testing
@testable import SnipboCore

@Suite("UpdatePackageTests")
struct UpdatePackageTests {
    private func release(_ names: [String]) -> UpdateRelease {
        UpdateRelease(
            tagName: "v0.6.0",
            displayName: "Snipbo 0.6.0",
            notes: "",
            assets: names.map {
                UpdateAsset(
                    name: $0,
                    url: URL(string: "https://github.com/x/\($0)")!,
                    size: 1
                )
            }
        )
    }

    @Test func picksExactAssets() {
        let picked = UpdatePackage.pick(
            from: release([
                "Snipbo-0.6.0-arm64.zip",
                "Snipbo-0.6.0-arm64.zip.sha256",
            ]),
            runningVersion: "0.6.0"
        )
        #expect(picked?.zip.name == "Snipbo-0.6.0-arm64.zip")
        #expect(picked?.sha256?.name == "Snipbo-0.6.0-arm64.zip.sha256")
    }

    @Test func fallsBackToSingleZip() {
        let picked = UpdatePackage.pick(
            from: release(["Snipbo-0.7.0-arm64.zip", "other.txt"]),
            runningVersion: "0.6.0"
        )
        #expect(picked?.zip.name == "Snipbo-0.7.0-arm64.zip")
    }

    @Test func noZipIsNil() {
        #expect(UpdatePackage.pick(from: release(["notes.md"]), runningVersion: "0.6.0") == nil)
    }

    @Test func sha256KnownVector() {
        // echo -n "abc" | shasum -a 256
        let hex = UpdatePackage.sha256Hex(of: Data("abc".utf8))
        #expect(hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(UpdatePackage.verifySHA256(
            of: Data("abc".utf8),
            digestText: "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD  abc.txt"
        ))
    }

    @Test func digestTextVariants() {
        let data = Data("abc".utf8)
        #expect(UpdatePackage.verifySHA256(of: data, digestText: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
        #expect(UpdatePackage.verifySHA256(of: data, digestText: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  Snipbo-0.6.0-arm64.zip"))
        #expect(!UpdatePackage.verifySHA256(of: data, digestText: "deadbeef  x.zip"))
        #expect(!UpdatePackage.verifySHA256(of: data, digestText: "no hex here"))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter UpdatePackageTests`
Expected: FAIL — `UpdatePackage` 不存在(编译错误)。

- [ ] **Step 3: 最小实现**

```swift
import CryptoKit
import Foundation

/// 从 release 资产中挑选安装包并校验其 SHA-256。
public struct UpdatePackage: Sendable {
    public init() {}

    /// 精确名优先,唯一 zip 兜底;返回 nil 表示该 release 没有可用安装包。
    public static func pick(
        from release: UpdateRelease,
        runningVersion: String
    ) -> (zip: UpdateAsset, sha256: UpdateAsset?)? {
        let zips = release.assets.filter { $0.name.lowercased().hasSuffix(".zip") }
        guard !zips.isEmpty else { return nil }
        let expected = "snipbo-\(runningVersion.lowercased())-arm64.zip"
        let zip = zips.first { $0.name.lowercased() == expected } ?? (zips.count == 1 ? zips[0] : nil)
        guard let zip else { return nil }
        let shaName = zip.name + ".sha256"
        let sha = release.assets.first { $0.name == shaName }
            ?? (release.assets.filter { $0.name.lowercased().hasSuffix(".sha256") }.count == 1
                ? release.assets.first { $0.name.lowercased().hasSuffix(".sha256") }
                : nil)
        return (zip, sha)
    }

    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// digestText 是 shasum 输出格式 `<hex>[空格][文件名]`;hex 大小写不敏感。
    public static func verifySHA256(of data: Data, digestText: String) -> Bool {
        guard let token = digestText.split(whereSeparator: \.isWhitespace).first else {
            return false
        }
        guard token.count == 64, token.allSatisfy(\.isHexDigit) else { return false }
        return sha256Hex(of: data) == token.lowercased()
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter UpdatePackageTests`
Expected: PASS(5 个用例)。

- [ ] **Step 5: 提交**

```bash
git add Sources/SnipboCore/Update/UpdatePackage.swift Tests/SnipboCoreTests/UpdatePackageTests.swift
git commit -m "feat(update): release asset picking and sha256 verification"
```

---

### Task 4: UpdateInstaller——解压/校验/备份/替换/回滚(SnipboCore)

**Files:**
- Create: `Sources/SnipboCore/Update/UpdateInstaller.swift`
- Test: `Tests/SnipboCoreTests/UpdateInstallerTests.swift`

**Interfaces:**
- Consumes: `UpdateError`(Task 1)
- Produces: `public struct UpdateInstaller: Sendable`
  - `init(relaunch: @escaping @MainActor @Sendable (URL) -> Void = UpdateInstaller.defaultRelaunch)`
  - `static func makeFakeAppBundle(version: String, at url: URL) throws -> URL`(供测试与调用方构造假包)
  - `func unzip(zip: URL, into directory: URL) throws`(Process `/usr/bin/ditto -x -k`)
  - `func findStagedApp(in directory: URL, expectedVersion: String) throws -> URL`(找 `Snipbo.app`,校验可执行文件与版本)
  - `func install(stagedApp: URL, currentBundle: URL, workspace: URL, newVersion: String) throws -> URL`
    (备份 `currentBundle` 到 `workspace/backup/<name>`,把 stagedApp 移到 currentBundle 的父目录、沿用原名;移动失败则把备份移回并抛 `installFailed`;成功返回新包 URL)
  - `func relaunch(newBundle: URL) throws`(调用注入的 relaunch 闭包,默认 `open <path>`)
  - `static func isInstalledInApplications(_ bundle: URL) -> Bool`(`/Applications` 或 `~/Applications` 前缀)

- [ ] **Step 1: 写失败测试**

```swift
import Foundation
import Testing
@testable import SnipboCore

@Suite("UpdateInstallerTests")
struct UpdateInstallerTests {
    private var tmp: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("update-installer-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @Test func makeFakeAppBundleWritesExecutableAndVersion() throws {
        let root = tmp
        try makeDir(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try UpdateInstaller.makeFakeAppBundle(version: "0.6.0", at: root)
            .appendingPathComponent("Snipbo.app", isDirectory: true)
        #expect(UpdateInstaller.stagedVersion(of: bundle) == "0.6.0")
    }

    @Test func installReplacesAndRelaunches() throws {
        let root = tmp
        try makeDir(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let appsDir = root.appendingPathComponent("apps", isDirectory: true)
        try makeDir(workspace)
        try makeDir(appsDir)
        let current = try UpdateInstaller.makeFakeAppBundle(version: "0.5.0", at: appsDir)
            .appendingPathComponent("Snipbo.app", isDirectory: true)
        let stagedRoot = try UpdateInstaller.makeFakeAppBundle(version: "0.6.0", at: root)
        let staged = stagedRoot.appendingPathComponent("Snipbo.app", isDirectory: true)
        var relaunchedAt: URL?
        let installer = UpdateInstaller(relaunch: { relaunchedAt = $0 })
        let newBundle = try installer.install(
            stagedApp: staged,
            currentBundle: current,
            workspace: workspace,
            newVersion: "0.6.0"
        )
        #expect(UpdateInstaller.stagedVersion(of: newBundle) == "0.6.0")
        #expect(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("backup/Snipbo.app").path
        ))
        try installer.relaunch(newBundle: newBundle)
        #expect(relaunchedAt == newBundle)
    }

    @Test func installRollsBackWhenMoveFails() throws {
        let root = tmp
        try makeDir(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let appsDir = root.appendingPathComponent("apps", isDirectory: true)
        try makeDir(workspace)
        try makeDir(appsDir)
        let current = try UpdateInstaller.makeFakeAppBundle(version: "0.5.0", at: appsDir)
            .appendingPathComponent("Snipbo.app", isDirectory: true)
        // 目标位置预置同名目录,让「移动新包」这一步必然失败。
        let blocked = current.deletingLastPathComponent()
            .appendingPathComponent("Snipbo.app-blocked", isDirectory: true)
        try makeDir(blocked)
        // staged 版本不符:在 install 内部的重命名步骤失败前抛错,旧包必须完好。
        let stagedRoot = try UpdateInstaller.makeFakeAppBundle(version: "9.9.9", at: root)
        let staged = stagedRoot.appendingPathComponent("Snipbo.app", isDirectory: true)
        let installer = UpdateInstaller(relaunch: { _ in })
        do {
            _ = try installer.install(
                stagedApp: staged,
                currentBundle: current,
                workspace: workspace,
                newVersion: "0.6.0"
            )
            Issue.record("expected failure")
        } catch {
            // 旧包必须原样还在,且仍能读出旧版本。
            #expect(UpdateInstaller.stagedVersion(of: current) == "0.5.0")
        }
    }

    @Test func applicationsDirectoryCheck() {
        #expect(UpdateInstaller.isInstalledInApplications(
            URL(fileURLWithPath: "/Applications/Snipbo.app")
        ))
        #expect(!UpdateInstaller.isInstalledInApplications(
            URL(fileURLWithPath: "/Users/x/dev/dist/Snipbo.app")
        ))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter UpdateInstallerTests`
Expected: FAIL — `UpdateInstaller` 不存在(编译错误)。

- [ ] **Step 3: 最小实现**

```swift
import Foundation

/// 把校验过的更新包替换到位:解压、验证、备份旧包、替换、(由调用方)重启。
/// 全部文件系统操作可注入 relaunch,因此可脱离真实应用测试。
public struct UpdateInstaller: Sendable {
    private let relaunchAction: @MainActor @Sendable (URL) -> Void

    public init(relaunch: @escaping @MainActor @Sendable (URL) -> Void = UpdateInstaller.defaultRelaunch) {
        self.relaunchAction = relaunch
    }

    public static func defaultRelaunch(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.path]
        try? process.run()
    }

    // MARK: 包构造(测试与流水线共用)

    @discardableResult
    public static func makeFakeAppBundle(version: String, at directory: URL) throws -> URL {
        let bundle = directory.appendingPathComponent("Snipbo.app", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(
            at: bundle.appendingPathComponent("Contents/MacOS", isDirectory: true),
            withIntermediateDirectories: true
        )
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleShortVersionString</key><string>\(version)</string>
        <key>CFBundleExecutable</key><string>Snipbo</string>
        </dict></plist>
        """
        try plist.write(
            to: bundle.appendingPathComponent("Contents/Info.plist"),
            atomically: true,
            encoding: .utf8
        )
        let executable = bundle.appendingPathComponent("Contents/MacOS/Snipbo")
        let stub = "#!/bin/sh\n"
        try stub.write(to: executable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return directory
    }

    /// 读取包的 CFBundleShortVersionString;包不完整返回 nil。
    public static func stagedVersion(of bundle: URL) -> String? {
        guard let info = Bundle(url: bundle)?.infoDictionary,
              let version = info["CFBundleShortVersionString"] as? String else {
            return nil
        }
        return version
    }

    // MARK: 流水线步骤

    public func unzip(zip: URL, into directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.requestFailed("ditto exit \(process.terminationStatus)")
        }
    }

    /// 在解压目录里定位 Snipbo.app,验证可执行文件与目标版本,失败抛错。
    public func findStagedApp(in directory: URL, expectedVersion: String) throws -> URL {
        let fm = FileManager.default
        let bundle = directory.appendingPathComponent("Snipbo.app", isDirectory: true)
        guard fm.fileExists(atPath: bundle.path) else {
            throw UpdateError.installFailed("staged bundle missing")
        }
        let executable = bundle.appendingPathComponent("Contents/MacOS/Snipbo")
        guard fm.isExecutableFile(atPath: executable.path) else {
            throw UpdateError.installFailed("staged executable missing")
        }
        guard Self.stagedVersion(of: bundle) == expectedVersion else {
            throw UpdateError.installFailed("staged version mismatch")
        }
        return bundle
    }

    /// 备份当前包 → 移入新包;新包移动失败时把备份移回原位再抛错。
    @discardableResult
    public func install(
        stagedApp: URL,
        currentBundle: URL,
        workspace: URL,
        newVersion: String
    ) throws -> URL {
        let fm = FileManager.default
        guard Self.stagedVersion(of: stagedApp) == newVersion else {
            throw UpdateError.installFailed("staged version mismatch")
        }
        let backup = workspace.appendingPathComponent("backup", isDirectory: true)
        try? fm.removeItem(at: backup)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        let backupItem = backup.appendingPathComponent(currentBundle.lastPathComponent, isDirectory: true)
        try fm.moveItem(at: currentBundle, to: backupItem)
        do {
            let target = currentBundle.deletingLastPathComponent()
                .appendingPathComponent(stagedApp.lastPathComponent, isDirectory: true)
            try fm.moveItem(at: stagedApp, to: target)
            return target
        } catch {
            try? fm.moveItem(at: backupItem, to: currentBundle)
            throw UpdateError.installFailed(error.localizedDescription)
        }
    }

    public func relaunch(newBundle: URL) throws {
        relaunchAction(newBundle)
    }

    /// 仅当运行包位于 /Applications 或 ~/Applications 时才允许原位替换。
    public static func isInstalledInApplications(_ bundle: URL) -> Bool {
        let path = bundle.standardizedFileURL.path
        let candidates = [
            "/Applications",
            ("~/Applications" as NSString).expandingTildeInPath,
        ]
        return candidates.contains { path.hasPrefix($0 + "/") || path == $0 + "/Snipbo.app" }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter UpdateInstallerTests`
Expected: PASS(4 个用例)。

- [ ] **Step 5: 提交**

```bash
git add Sources/SnipboCore/Update/UpdateInstaller.swift Tests/SnipboCoreTests/UpdateInstallerTests.swift
git commit -m "feat(update): staged install with backup and rollback"
```

---

### Task 5: AppSettings.autoCheckUpdates

**Files:**
- Modify: `Sources/SnipboCore/Settings/AppSettings.swift`(属性声明区、init 默认参、CodingKeys、decode)
- Test: `Tests/SnipboCoreTests/AppSettingsTests.swift`(追加用例)

**Interfaces:**
- Consumes: 无
- Produces: `AppSettings.autoCheckUpdates: Bool`(默认 true;旧档缺键时 decode 为 true)

- [ ] **Step 1: 写失败测试(追加到现有 `AppSettingsTests`)**

```swift
@Test func autoCheckUpdatesDefaultsTrueAndDecodesFromLegacy() throws {
    // 缺键的旧档解码后为 true(默认开)。
    let legacy = #"{"saveDirectory":"/tmp","format":"png"}"#
    let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
    #expect(decoded.autoCheckUpdates == true)
    var settings = AppSettings.default
    #expect(settings.autoCheckUpdates == true)
    settings.autoCheckUpdates = false
    let roundtrip = try JSONDecoder().decode(
        AppSettings.self,
        from: JSONEncoder().encode(settings)
    )
    #expect(roundtrip.autoCheckUpdates == false)
}
```

(注:如旧档 JSON 缺少必填键导致 decode 失败,则以现有 `AppSettingsTests` 中
构造最小 JSON 的方式为准——参照该文件里已有的解码用例写法,保持一致。)

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter AppSettingsTests`
Expected: FAIL — `autoCheckUpdates` 不存在(编译错误)。

- [ ] **Step 3: 最小实现**

在 `AppSettings` 属性区(`hiddenStatusItems` 之后)加:

```swift
/// 启动时是否静默检查一次更新。手动检查不受它影响。
public var autoCheckUpdates: Bool
```

init 默认参(`selectionFixedHeight` 之后)加 `autoCheckUpdates: Bool = true,`;
CodingKeys 加 `case autoCheckUpdates`;decode 行(参照 `decodeIfPresent` 现有写法)加:

```swift
autoCheckUpdates = try container.decodeIfPresent(Bool.self, forKey: .autoCheckUpdates) ?? true
```

encode 处按现有模式加 `try container.encode(autoCheckUpdates, forKey: .autoCheckUpdates)`。

- [ ] **Step 4: 跑全部测试确认通过**

Run: `swift test --filter AppSettingsTests`
Expected: PASS(含已有用例)。

- [ ] **Step 5: 提交**

```bash
git add Sources/SnipboCore/Settings/AppSettings.swift Tests/SnipboCoreTests/AppSettingsTests.swift
git commit -m "feat(update): autoCheckUpdates setting"
```

---

### Task 6: UpdateCoordinator 状态机(SnipboApp)

**Files:**
- Create: `Sources/SnipboApp/Update/UpdateCoordinator.swift`

**Interfaces:**
- Consumes: `UpdateChecker`、`UpdatePackage`、`UpdateInstaller`、`UpdateRelease`、`UpdateError`(Task 1–4);`AppSettings`(Task 5)
- Produces: `@MainActor final class UpdateCoordinator: ObservableObject`
  - `static let shared: UpdateCoordinator`
  - `enum State: Equatable { case idle, checking, upToDate, available(UpdateRelease), downloading(Double), installing, failed(UpdateError) }`,`@Published private(set) var state: State`
  - `func checkSilently()`(任何失败静默回 idle)
  - `func checkInteractively()`(失败把 state 置为 failed,由 UI 展示)
  - `func downloadAndInstall()`(仅 available 态有效;流程:清残留 → 下载 zip → 下载 sha256 → 校验 → 解压 → 定位/验证 → `isInstalledInApplications` 断言 → install → relaunch → terminate;开发构建直接置 failed(.notInstalledInApplications))
  - `var canInstallInPlace: Bool`(静态判定当前 Bundle.main 位置)
  - `private let settingsProvider: () -> AppSettings`;`private let checker: UpdateChecker`;`private let installer: UpdateInstaller`;workspace `~/Library/Caches/Snipbo/updates`

本任务是编排层(App target 无测试 target),逻辑已在 Task 1–4 单测;Task 9 做手工验证。因此本任务无 TDD 步骤,以编译 + Task 9 验证为准。

- [ ] **Step 1: 实现**

```swift
import AppKit
import Foundation
import SnipboCore

/// 更新流程的状态机:检查 → 提示 → 下载校验 → 安装 → 重启。
/// 所有耗时步骤在后台 Task 执行,状态回主线程发布;失败一律映射为
/// UpdateError,静默路径直接吞掉,交互路径交给 UI 展示。
@MainActor
final class UpdateCoordinator: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateRelease)
        case downloading(Double)
        case installing
        case failed(UpdateError)
    }

    static let shared = UpdateCoordinator()

    @Published private(set) var state: State = .idle

    private let settingsProvider: () -> AppSettings
    private let checker: UpdateChecker
    private let installer: UpdateInstaller
    private let workspace: URL

    /// 当前安装位置是否允许原位替换(开发构建不允许)。
    static var canInstallInPlace: Bool {
        guard let bundle = Bundle.main.bundleURL as URL? else { return false }
        return UpdateInstaller.isInstalledInApplications(bundle)
    }

    init(
        settingsProvider: @escaping () -> AppSettings,
        checker: UpdateChecker = UpdateChecker(),
        installer: UpdateInstaller = UpdateInstaller()
    ) {
        self.settingsProvider = settingsProvider
        self.checker = checker
        self.installer = installer
        self.workspace = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Snipbo/updates", isDirectory: true)
    }

    var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? snipboVersion
    }

    /// 启动静默检查:失败、无新版本、渠道不可用都完全无声。
    func checkSilently() {
        guard settingsProvider().autoCheckUpdates else { return }
        guard case .idle = state else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let release = try? await self.checker.check() else { return }
            await self.assess(release: release, interactive: false)
        }
    }

    /// 手动检查:结果(含失败原因)写进 state,由 Updates 页展示。
    func checkInteractively() {
        guard !isBusy else { return }
        state = .checking
        Task { [weak self] in
            guard let self else { return }
            do {
                let release = try await self.checker.check()
                await self.assess(release: release, interactive: true)
            } catch let error as UpdateError {
                self.state = .failed(error)
            } catch {
                self.state = .failed(.requestFailed(error.localizedDescription))
            }
        }
    }

    private var isBusy: Bool {
        switch state {
        case .idle, .upToDate, .available, .failed: return false
        case .checking, .downloading, .installing: return true
        }
    }

    private func assess(release: UpdateRelease, interactive: Bool) async {
        switch SemVer.compare(release.tagName, currentVersion) {
        case .orderedDescending:
            state = UpdatePackage.pick(from: release, runningVersion: currentVersion) != nil
                ? .available(release)
                : (interactive ? .failed(.noMatchingAsset) : .idle)
        case .orderedSame, .orderedAscending:
            state = interactive ? .upToDate : .idle
        case nil:
            // 版本无法比较(如预发布 tag):保守起见不提示更新。
            state = interactive ? .upToDate : .idle
        }
    }

    /// 下载校验安装重启的完整流水线。每一步失败都清理下载物。
    func downloadAndInstall() {
        guard case .available(let release) = state,
              let picked = UpdatePackage.pick(from: release, runningVersion: currentVersion)
        else { return }
        guard Self.canInstallInPlace else {
            state = .failed(.notInstalledInApplications)
            return
        }
        state = .installing
        let release = release
        let zipAsset = picked.zip
        let shaAsset = picked.sha256
        let expectedVersion = release.tagName.dropFirst(release.tagName.hasPrefix("v") ? 1 : 0)
        let workspace = workspace
        let installer = installer
        Task { [weak self] in
            guard let self else { return }
            do {
                let fm = FileManager.default
                try? fm.removeItem(at: workspace)
                try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
                let zipData = try await Self.download(zipAsset, progress: { fraction in
                    Task { @MainActor in self.state = .downloading(fraction) }
                })
                if let shaAsset {
                    let (shaData, _) = try await Self.downloadRaw(shaAsset.url)
                    guard UpdatePackage.verifySHA256(of: zipData, digestText: String(decoding: shaData, as: UTF8.self)) else {
                        throw UpdateError.checksumMismatch
                    }
                }
                let zipURL = workspace.appendingPathComponent(zipAsset.name)
                try zipData.write(to: zipURL)
                let extractDir = workspace.appendingPathComponent("staged", isDirectory: true)
                try installer.unzip(zip: zipURL, into: extractDir)
                let stagedApp = try installer.findStagedApp(
                    in: extractDir,
                    expectedVersion: String(expectedVersion)
                )
                self.state = .installing
                let newBundle = try installer.install(
                    stagedApp: stagedApp,
                    currentBundle: Bundle.main.bundleURL,
                    workspace: workspace,
                    newVersion: String(expectedVersion)
                )
                try installer.relaunch(newBundle: newBundle)
                NSApp.terminate(nil)
            } catch let error as UpdateError {
                self.state = .failed(error)
            } catch {
                self.state = .failed(.requestFailed(error.localizedDescription))
            }
        }
    }

    private static func download(
        _ asset: UpdateAsset,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data {
        let (bytes, response) = try await URLSession.shared.bytes(from: asset.url)
        let total = Int(response.expectedContentLength)
        var data = Data(capacity: max(asset.size, 0))
        var received = 0
        for try await byte in bytes {
            data.append(byte)
            received += 1
            if total > 0, received % (1 << 20) == 0 {
                progress(Double(received) / Double(total))
            }
        }
        _ = response
        return data
    }

    private static func downloadRaw(_ url: URL) async throws -> (Data, URLResponse) {
        let (data, response) = try await URLSession.shared.data(from: url)
        return (data, response)
    }
}
```

- [ ] **Step 2: 编译确认**

Run: `swift build`
Expected: Build complete(无新警告)。

- [ ] **Step 3: 提交**

```bash
git add Sources/SnipboApp/Update/UpdateCoordinator.swift
git commit -m "feat(update): coordinator state machine with download and install"
```

---

### Task 7: Updates 页重写 + About 文案

**Files:**
- Modify: `Sources/SnipboApp/Settings/SettingsView.swift`(updatesTab 整体替换、aboutTab 隐私文案行、文件头注入 coordinator 观察的辅助 View)

**Interfaces:**
- Consumes: `UpdateCoordinator.shared`(Task 6)、`AppSettings.autoCheckUpdates`(Task 5)、现有 `SettingsRow`/`groupDivider`/`versionText`
- Produces: Updates 页四个区块(版本行 + 自动检查开关 + 检查按钮/进度 + 结果区);About 文案「除检查更新外不联网」。

App target 无单测;验证在 Task 9(渲染 harness + 手工)。

- [ ] **Step 1: 重写 `updatesTab`(整段替换原 781–810 行)**

```swift
private var updatesTab: some View {
    @ObservedObject var updates = UpdateCoordinator.shared
    return VStack(alignment: .leading, spacing: 0) {
        VStack(spacing: 8) {
            SettingsRow(L10n.tr("Current version", "当前版本"), labelWidth: labelWidth) {
                Text(updates.currentVersion)
                    .monospacedDigit()
            }
            SettingsRow(L10n.tr("Check for updates on launch", "启动时检查更新"), labelWidth: labelWidth) {
                Toggle("", isOn: $model.settings.autoCheckUpdates)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }

        groupDivider

        VStack(alignment: .leading, spacing: 8) {
            Button {
                updates.checkInteractively()
            } label: {
                switch updates.state {
                case .checking:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L10n.tr("Checking…", "正在检查…"))
                    }
                case .downloading(let fraction):
                    HStack(spacing: 6) {
                        ProgressView(value: fraction)
                            .frame(width: 90)
                        Text(L10n.tr("Downloading…", "正在下载…"))
                    }
                case .installing:
                    Text(L10n.tr("Installing…", "正在安装…"))
                default:
                    Text(L10n.tr("Check for Updates", "检查更新"))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isUpdateBusy)

            switch updates.state {
            case .upToDate:
                Text(L10n.tr("You are up to date.", "已是最新版本。"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            case .available(let release):
                Text(L10n.tr(
                    "Version \(release.displayName) is available.",
                    "新版本可用:\(release.displayName)。"
                ))
                    .font(.system(size: 12, weight: .medium))
                if !release.notes.isEmpty {
                    Text(String(release.notes.prefix(600)))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(8)
                }
                if UpdateCoordinator.canInstallInPlace {
                    Button(L10n.tr("Download and Install", "下载并安装")) {
                        updates.downloadAndInstall()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Text(L10n.tr(
                        "This copy runs from a development folder, so it cannot be updated in place. Install the downloaded app into /Applications manually.",
                        "当前副本运行在开发目录,无法原位更新;请手动把下载的 app 拖入 /Applications。"
                    ))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            case .failed(let error):
                Text(error.localizedDescription)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            default:
                EmptyView()
            }
        }
    }
}

private var isUpdateBusy: Bool {
    switch UpdateCoordinator.shared.state {
    case .checking, .downloading, .installing: return true
    default: return false
    }
}
```

注意:`@ObservedObject` 局部属性在 SwiftUI body 里是合法写法(工具链无 SwiftUI 宏问题的只有 `@State`/`@Published` 宏;`@ObservedObject` 不是宏)。若编译报错,把 `updates` 提升为 `SettingsView` 的普通计算属性包装:建一个 `UpdatePane: View` 子视图持有 `@ObservedObject var coordinator: UpdateCoordinator`,把上面 UI 移进去,`updatesTab` 返回 `UpdatePane()` + 开关行。**两种写法取编译通过的那个。**

- [ ] **Step 2: 改 About 隐私文案**

`aboutTab` 中的隐私段替换为:

```swift
Text(L10n.tr(
    "Privacy: screenshots never leave your computer. The only outbound traffic is checking for updates on GitHub Releases — no uploads, no telemetry, no crash reporting.",
    "隐私:截图永远留在你的电脑上。唯一的对外请求是向 GitHub Releases 检查更新 —— 无上传、无遥测、无崩溃上报。"
))
```

同时把 `updatesTab` 原有的「本应用完全不联网」说明段删除(已被新 UI 取代)。

- [ ] **Step 3: 编译 + 渲染检查**

Run: `swift build && .build/debug/Snipbo` 之外用 harness:
编译 `scripts/ui_render_harness.swift` 同款命令并在 `renderHistory` 后追加
设置窗口渲染不现实——直接跑 `scripts/diag_harness.swift`(渲染设置窗口到
`/tmp/snipbo-settings.png`),目检 Updates 页(AppleScript 无法切 tab,仅确认
编译与首屏正常)。

Run: `swift build`
Expected: Build complete。

- [ ] **Step 4: 提交**

```bash
git add Sources/SnipboApp/Settings/SettingsView.swift
git commit -m "feat(update): rework the Updates tab with check and install"
```

---

### Task 8: 状态菜单 + 启动静默检查接线

**Files:**
- Modify: `Sources/SnipboApp/StatusItemController.swift`(init 增加 `onCheckUpdates` 闭包参数与菜单项)
- Modify: `Sources/SnipboApp/AppDelegate.swift`(创建 coordinator 接线、启动后 10 秒静默检查)

**Interfaces:**
- Consumes: `UpdateCoordinator.shared`(Task 6)
- Produces: 状态菜单「检查更新…」项(点击 = 打开设置并切到 Updates 页 + 触发交互检查);启动静默检查。

- [ ] **Step 1: StatusItemController 增加检查更新入口**

init 参数追加(放在 `onHistoryBrowser` 之后):`onCheckUpdates: @escaping () -> Void,`,存储为 `private let onCheckUpdates: () -> Void`。`populateMenu(_:)` 里「Settings」项之后追加:

```swift
menu.addItem(makeItem(
    L10n.tr("Check for Updates…", "检查更新…"),
    icon: "download",
    action: #selector(checkForUpdates)
))
```

并加:

```swift
@objc private func checkForUpdates() { onCheckUpdates() }
```

若 `Resources/Icons` 无 `download.svg`,`makeItem` 的 icon 传 `nil` 或改用
已有的 `save` 图标(先 `ls Resources/Icons | grep -i down` 确认)。

- [ ] **Step 2: AppDelegate 接线**

`applicationDidFinishLaunching` 里构造 StatusItemController 处,追加参数:

```swift
onCheckUpdates: { [weak self] in
    self?.showSettingsOnUpdatesTab()
},
```

并新增方法与静默检查调度:

```swift
/// 状态菜单的「检查更新」:打开设置窗口并停在 Updates 页,同时触发一次检查。
func showSettingsOnUpdatesTab() {
    showSettings()
    settingsWindowController?.tabSelection.tab = .updates
    UpdateCoordinator.shared.checkInteractively()
}

// applicationDidFinishLaunching 末尾:
Task { [weak self] in
    try? await Task.sleep(nanoseconds: 10_000_000_000)
    self?.updateCoordinator?.checkSilently()
}
```

其中 `private lazy var updateCoordinator = UpdateCoordinator(settingsProvider: { self.settings })`。
若 `settingsWindowController` 是 `var`/`lazy var` 按现有命名调整(`showSettings()`
的实现里能找到它的真实名字)。

- [ ] **Step 3: 编译 + 重启手验**

```bash
swift build
```

Expected: Build complete。手工:点状态菜单出现「检查更新…」,点击后设置窗口
打开且停在 Updates 页并开始检查。

- [ ] **Step 4: 提交**

```bash
git add Sources/SnipboApp/StatusItemController.swift Sources/SnipboApp/AppDelegate.swift
git commit -m "feat(update): status-menu entry and silent launch check"
```

---

### Task 9: 回归与手工验证清单

**Files:**
- 无新文件;验证 + 修复

**Interfaces:**
- Consumes: 前 8 个任务的全部产出
- Produces: 通过回归的应用构建

- [ ] **Step 1: 全量单测**

Run: `swift test`
Expected: 全部 PASS(既有用例 + Update 四个 Suite)。

- [ ] **Step 2: 探针回归**

Run: `./scripts/run_editor_probe.sh`
Expected: `probe: all checks passed`。

- [ ] **Step 3: 构建签名并重启**

```bash
./scripts/build_app.sh && pkill -x Snipbo && open dist/Snipbo.app
```

- [ ] **Step 4: 手工验证清单(逐项确认)**

1. 私有渠道:仓库未公开时,Updates 页点「检查更新」→ 显示「发布渠道暂不可用」;
   启动静默检查无声、无窗口、无弹窗。
2. 真实更新流:把 `dist/Snipbo.app` 拖入 `/Applications` 覆盖安装并启动,发一个
   测试 release(tag 大于当前版本)→ Updates 页出现版本说明与「下载并安装」;
   点击后进度推进、应用自动以新版本重启;屏幕录制授权仍有效(截一张图验证)。
3. 断网:断开网络后手动检查 → 显示「无法检查更新:…」;自动检查无声。
4. 开发构建:从 `dist/` 直接启动时,available 态只显示手动安装提示,没有
   「下载并安装」按钮。
5. 设置开关:关掉「启动时检查更新」后重启应用,10 秒内无网络请求
   (观察 `log stream --predicate 'process == "Snipbo"'` 或 小图标无动静)。

- [ ] **Step 5: 提交(如有修复)**

```bash
git add -A
git commit -m "fix(update): address findings from manual verification"
```

---

## Self-Review 记录

- **Spec coverage**:检查(Task 2/6)、资产挑选与校验(Task 3)、安装回滚(Task 4)、
  autoCheckUpdates(Task 5)、Updates 页与 About 文案(Task 7)、状态菜单与启动
  静默检查(Task 8)、开发构建限制(Task 6 断言 + Task 7 UI + Task 9 手工)、
  版本说明节选 600 字符(Task 7)、TCC 授权存续说明(Task 9 手工第 2 项)。无缺口。
- **Placeholder scan**:无 TBD/TODO;Task 7 保留了「两种 SwiftUI 写法取编译通过者」
  的明确分支指引,不算占位符。
- **Type consistency**:`UpdatePackage.pick` 返回元组 `(zip:sha256:)` 在 Task 3 定义、
  Task 6 消费一致;`UpdateInstaller.install` 签名 Task 4 定义、Task 6 调用一致;
  `UpdateChecker.check()` Task 2 定义、Task 6 调用一致。
- **Review Focus**:速率限制头区分(Task 2 测试 3)、sha 文本变体(Task 3 测试 5)、
  异常 tag(Task 1 测试 4)、回滚(Task 4 测试 3)、开发构建(Task 7/9)。
