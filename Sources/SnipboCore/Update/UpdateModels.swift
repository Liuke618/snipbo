import Foundation

// SnipboCore cannot see the app target's L10n, so the updater carries its own
// minimal mirror of it (same bilingual contract: `tr("English", "中文")`).
// `setLanguage` is public so the app target can keep this mirror in sync with
// its own L10n (the app's copy shadows this one for unqualified lookups);
// `tr`/`isChinese` stay internal and are only used inside SnipboCore.
public enum L10n {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var language: AppLanguage = .system

    public static func setLanguage(_ language: AppLanguage) {
        lock.lock()
        defer { lock.unlock() }
        self.language = language
    }

    static var isChinese: Bool {
        lock.lock()
        defer { lock.unlock() }
        return language.isChinese
    }

    static func tr(_ en: String, _ zh: String) -> String {
        lock.lock()
        let chinese = language.isChinese
        lock.unlock()
        return chinese ? zh : en
    }
}

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
public struct SemVer: Comparable, Equatable, Sendable, CustomStringConvertible {
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

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
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
