import Foundation

/// UI language for every user-facing string. `system` resolves the first
/// preferred language that the app supports (English or Simplified Chinese).
public enum AppLanguage: String, Codable, Sendable, CaseIterable {
    case system
    case english = "en"
    case chinese = "zh-Hans"

    /// Resolves to a concrete language code ("en" or "zh-Hans").
    public var resolved: String {
        switch self {
        case .english: return "en"
        case .chinese: return "zh-Hans"
        case .system: return AppLanguage.resolveSystem(Locale.preferredLanguages)
        }
    }

    public var isChinese: Bool { resolved == "zh-Hans" }

    /// Resolution with an injectable preferred-language list for tests.
    public func resolve(_ preferred: [String]) -> String {
        guard self == .system else { return resolved }
        return AppLanguage.resolveSystem(preferred)
    }

    private static func resolveSystem(_ preferred: [String]) -> String {
        for language in preferred {
            if language.hasPrefix("zh") { return "zh-Hans" }
            if language.hasPrefix("en") { return "en" }
        }
        return "en"
    }
}
