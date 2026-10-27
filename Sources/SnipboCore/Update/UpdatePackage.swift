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
