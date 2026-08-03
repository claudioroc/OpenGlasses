import Foundation

/// Maps anonymous diarization speaker ids (`0, 1, 2, …`) to optional human names and a stable
/// display colour, and persists the names. Pure logic over an injectable `UserDefaults` so it's
/// fully unit-testable (tests pass a throwaway suite).
///
/// "Merge on same name": if two ids are given the same name they're treated as one person —
/// `canonicalId(for:)` returns the lowest id sharing that name, so attribution and colour stay
/// consistent when Deepgram assigns a returning speaker a fresh id.
final class SpeakerRegistry {
    /// Number of distinct display colours; the view maps `colorIndex(for:)` onto its palette.
    static let paletteSize = 8

    private let defaults: UserDefaults
    private let storageKey: String
    private var names: [Int: String]

    /// Optional side-effect when a non-empty name is assigned (e.g. push to cortex via glasses-router).
    /// Left `nil` in unit tests so the registry stays pure.
    var onNameSet: ((Int, String) -> Void)?

    init(defaults: UserDefaults = .standard, storageKey: String = "diarizationSpeakerNames") {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            self.names = Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
                Int(key).map { ($0, value) }
            })
        } else {
            self.names = [:]
        }
    }

    // MARK: - Names

    /// The speaker ids that currently have a name, ascending — for the "name speakers" list.
    var namedSpeakerIds: [Int] {
        names.keys.sorted()
    }

    /// The assigned name for `id`, or `nil` if it hasn't been named.
    func name(for id: Int) -> String? {
        names[id]
    }

    /// Assign (or clear, with `nil`/empty) the name for `id`, and persist.
    /// When a non-empty name is set, also fires `onNameSet` (cortex sync).
    func setName(_ name: String?, for id: Int) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            names[id] = trimmed
            persist()
            onNameSet?(id, trimmed)
        } else {
            names.removeValue(forKey: id)
            persist()
        }
    }

    // MARK: - Display

    /// What to show on a chip: the name if set, else `"Speaker N"` (1-based), else `"Speaker"`
    /// for an unlabeled (`nil`) segment.
    func displayLabel(for id: Int?) -> String {
        guard let id else { return "Speaker" }
        if let name = names[canonicalId(for: id)] { return name }
        return "Speaker \(id + 1)"
    }

    /// A deterministic palette index for `id` (stable across launches; shared by merged ids).
    /// Returns `0` for `nil` so unlabeled segments get a consistent neutral slot.
    func colorIndex(for id: Int?) -> Int {
        guard let id else { return 0 }
        return ((canonicalId(for: id) % Self.paletteSize) + Self.paletteSize) % Self.paletteSize
    }

    /// The lowest id sharing `id`'s name (merge-on-same-name), or `id` itself if unnamed/unique.
    func canonicalId(for id: Int) -> Int {
        guard let name = names[id] else { return id }
        return names.filter { $0.value == name }.keys.min() ?? id
    }

    // MARK: - Persistence

    private func persist() {
        let encodable = Dictionary(uniqueKeysWithValues: names.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(encodable) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
