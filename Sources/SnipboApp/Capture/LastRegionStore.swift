import Foundation
import SnipboCore

struct NamedRegion: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var region: LastRegion
}

@MainActor
final class LastRegionStore {
    private let defaults: UserDefaults
    private let key = "capture.lastRegion.v1"
    private let presetsKey = "capture.regionPresets.v1"

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

    func presets() -> [NamedRegion] {
        guard let data = defaults.data(forKey: presetsKey) else { return [] }
        guard let presets = try? JSONDecoder().decode([NamedRegion].self, from: data) else {
            defaults.removeObject(forKey: presetsKey)
            return []
        }
        return presets
    }

    /// Saves a named preset, replacing an existing one with the same name
    /// case-insensitively so the menu does not fill with duplicates.
    @discardableResult
    func savePreset(name: String, region: LastRegion) -> NamedRegion? {
        let trimmed = String(
            name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)
        )
        guard !trimmed.isEmpty else { return nil }
        var list = presets()
        if let index = list.firstIndex(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            let updated = NamedRegion(
                id: list[index].id,
                name: trimmed,
                region: region
            )
            list[index] = updated
            persist(list)
            return updated
        }
        let preset = NamedRegion(id: UUID(), name: trimmed, region: region)
        list.append(preset)
        persist(list)
        return preset
    }

    func removePreset(id: UUID) {
        persist(presets().filter { $0.id != id })
    }

    private func persist(_ presets: [NamedRegion]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: presetsKey)
    }
}
