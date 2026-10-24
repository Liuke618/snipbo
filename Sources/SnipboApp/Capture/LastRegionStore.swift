import Foundation
import SnipboCore

@MainActor
final class LastRegionStore {
    private let defaults: UserDefaults
    private let key = "capture.lastRegion.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> LastRegion? {
        guard let data = defaults.data(forKey: key) else { return nil }
        guard let region = try? JSONDecoder().decode(LastRegion.self, from: data) else {
            // A corrupt payload must not keep the menu enabled forever.
            defaults.removeObject(forKey: key)
            return nil
        }
        return region
    }

    func save(_ region: LastRegion) {
        guard let data = try? JSONEncoder().encode(region) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
