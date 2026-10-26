import Foundation
import SnipboCore

/// Bilingual UI strings. Call sites pass the English and Chinese variants
/// side by side. The resolved language is lock-protected so error descriptions
/// (which are nonisolated) can translate from background threads too.
enum L10n {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var language: AppLanguage = .system

    static func setLanguage(_ language: AppLanguage) {
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
