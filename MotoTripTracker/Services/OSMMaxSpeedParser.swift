import Foundation

/// Parses OpenStreetMap `maxspeed` tag values into km/h.
enum OSMMaxSpeedParser {
    /// Country-specific implicit limits (km/h). Extend as needed.
    private static let implicitLimits: [String: Int] = [
        "gr:urban": 50,
        "gr:rural": 90,
        "gr:trunk": 110,
        "gr:motorway": 130,
        "gr:living_street": 20,
        "urban": 50,
        "rural": 90,
        "trunk": 110,
        "motorway": 130,
        "living_street": 20,
        "walk": 5,
        "none": 0
    ]

    static func parseKmh(_ raw: String) -> Int? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }

        if let implicit = implicitLimits[value] {
            return implicit == 0 ? nil : implicit
        }

        // Variable / advisory limits — not a fixed number.
        if value == "signals" || value == "variable" || value.hasPrefix("maxspeed:variable") {
            return nil
        }

        // "50 mph", "30 mph"
        if value.contains("mph") {
            let digits = value.filter { $0.isNumber || $0 == "." }
            guard let mph = Double(digits) else { return nil }
            return Int((mph * 1.60934).rounded())
        }

        // "50 km/h", "50 kph", or plain "50"
        let digits = value
            .replacingOccurrences(of: "km/h", with: "")
            .replacingOccurrences(of: "kph", with: "")
            .trimmingCharacters(in: .whitespaces)
        if let kmh = Int(digits.filter { $0.isNumber }) {
            return kmh > 0 ? kmh : nil
        }

        return nil
    }

    /// Greek / generic OSM defaults when a way has no `maxspeed` tag.
    static func impliedKmh(forHighway highway: String) -> Int? {
        switch highway {
        case "motorway", "motorway_link": 130
        case "trunk", "trunk_link": 110
        case "primary", "primary_link": 90
        case "secondary", "secondary_link": 90
        case "tertiary", "tertiary_link": 60
        case "unclassified", "residential": 50
        case "living_street": 20
        case "service": 30
        default: nil
        }
    }
}
