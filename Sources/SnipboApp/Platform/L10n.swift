import Foundation
import SnipboCore

/// Bilingual UI strings. Call sites pass the English and Chinese variants
/// side by side — `tr` picks by the live setting, so a language change takes
/// effect wherever views re-render. AppDelegate points `languageProvider` at
/// the settings model.
@MainActor
enum L10n {
    static var languageProvider: () -> AppLanguage = { .system }

    static var isChinese: Bool { languageProvider().isChinese }

    static func tr(_ en: String, _ zh: String) -> String {
        isChinese ? zh : en
    }
}
