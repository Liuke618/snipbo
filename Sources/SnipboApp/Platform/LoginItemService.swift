import Foundation
import ServiceManagement
import os

/// Aligns the macOS login item with the persisted setting.
enum LoginItemService {
    private static let logger = Logger(subsystem: "local.snipbo.app", category: "LoginItem")

    static func isEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Idempotent; failures are logged, never fatal. SMAppService can refuse
    /// when the bundle moved or the user denied the request — the setting
    /// stays as chosen and the next launch retries.
    static func sync(enabled: Bool) {
        let status = SMAppService.mainApp.status
        if enabled, status == .enabled { return }
        if !enabled, status == .notRegistered { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error(
                "Could not \(enabled ? "register" : "unregister", privacy: .public) the login item: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
