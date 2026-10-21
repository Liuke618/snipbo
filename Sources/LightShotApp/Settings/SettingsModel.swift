import Combine
import Foundation
import LightShotCore

/// Persisted application settings.
///
/// Every mutation of `settings` (including mutations made through a SwiftUI
/// binding to a nested property) is saved to `UserDefaults` and reported to
/// `onChange`, which the app uses to apply the new values live.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var settings: AppSettings {
        didSet { persist() }
    }

    /// Called after every persisted change. Not called during initialization.
    var onChange: ((AppSettings) -> Void)?

    private let defaults: UserDefaults
    private static let storageKey = "settings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded.normalized()
        } else {
            self.settings = AppSettings.default
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.storageKey)
        }
        onChange?(settings)
    }
}
