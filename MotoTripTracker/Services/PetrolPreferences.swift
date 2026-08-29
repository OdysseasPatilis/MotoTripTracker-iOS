import Foundation

/// Saved preferences for recommending petrol stations (brand order + fuel grades).
@Observable
@MainActor
final class PetrolPreferences {
    private static let brandsKey = "moto.petrol.preferredBrands"
    private static let octanesKey = "moto.petrol.preferredOctanes"

    /// Default brand priority — Greece-relevant first, then common international brands.
    static let catalog: [String] = [
        "Shell", "BP", "EKO", "Avin", "Jet Oil", "Revoil", "Aegean", "Elf", "Total", "Q8", "Esso"
    ]

    /// Ordered brand preference (index 0 = highest priority).
    var preferredBrands: [String] {
        didSet { persistBrands() }
    }

    /// Preferred petrol grades, e.g. 98 and 100.
    var preferredOctanes: Set<Int> {
        didSet { persistOctanes() }
    }

    init() {
        let defaults = UserDefaults.standard
        if let stored = defaults.array(forKey: Self.brandsKey) as? [String], !stored.isEmpty {
            preferredBrands = stored
        } else {
            // Sensible defaults matching the user's stated preference.
            preferredBrands = ["Shell", "BP"]
        }

        if let stored = defaults.array(forKey: Self.octanesKey) as? [Int], !stored.isEmpty {
            preferredOctanes = Set(stored)
        } else {
            preferredOctanes = [98, 100]
        }
    }

    func brandRank(for rawBrand: String?) -> Int {
        guard let rawBrand, !rawBrand.isEmpty else { return preferredBrands.count + 5 }
        let needle = Self.normalize(rawBrand)
        if let index = preferredBrands.firstIndex(where: { Self.normalize($0) == needle }) {
            return index
        }
        // Partial match: "Shell Select" contains Shell
        if let index = preferredBrands.firstIndex(where: { needle.contains(Self.normalize($0)) || Self.normalize($0).contains(needle) }) {
            return index
        }
        return preferredBrands.count + 5
    }

    func isPreferredBrand(_ rawBrand: String?) -> Bool {
        brandRank(for: rawBrand) < preferredBrands.count
    }

    func toggleBrand(_ brand: String) {
        if let index = preferredBrands.firstIndex(of: brand) {
            preferredBrands.remove(at: index)
        } else {
            preferredBrands.append(brand)
        }
    }

    func moveBrand(from source: IndexSet, to destination: Int) {
        var brands = preferredBrands
        let moving = source.sorted().map { brands[$0] }
        for index in source.sorted(by: >) {
            brands.remove(at: index)
        }
        var insertAt = destination
        for index in source where index < destination {
            insertAt -= 1
        }
        insertAt = max(0, min(insertAt, brands.count))
        brands.insert(contentsOf: moving, at: insertAt)
        preferredBrands = brands
    }

    func toggleOctane(_ octane: Int) {
        if preferredOctanes.contains(octane) {
            preferredOctanes.remove(octane)
        } else {
            preferredOctanes.insert(octane)
        }
    }

    private func persistBrands() {
        UserDefaults.standard.set(preferredBrands, forKey: Self.brandsKey)
    }

    private func persistOctanes() {
        UserDefaults.standard.set(Array(preferredOctanes).sorted(), forKey: Self.octanesKey)
    }

    static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
