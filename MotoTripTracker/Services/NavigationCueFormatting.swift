import CoreLocation
import Foundation

/// Compact copy for the in-navigation glance chip and bottom bar.
enum NavigationCueFormatting {
    /// "120 m Ermou" from a MapKit instruction and the live distance to that maneuver.
    static func chipText(distanceMeters: CLLocationDistance, instruction: String) -> String {
        let distance = NavigationRouteMath.formatDistance(distanceMeters)
        let label = compactLabel(from: instruction)
        guard !label.isEmpty else { return distance }
        return "\(distance) \(label)"
    }

    /// Short street name when the instruction names one, otherwise a one-word maneuver.
    static func compactLabel(from instruction: String) -> String {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if let street = streetName(in: trimmed) {
            return clipped(street, limit: 22)
        }
        return clipped(fallbackManeuver(from: trimmed), limit: 22)
    }

    /// Remaining moto ETA for the slim bar. "--" when guidance has no arrival time.
    static func remainingTimeLabel(until eta: Date?, now: Date = .now) -> String {
        guard let eta else { return "--" }
        let seconds = eta.timeIntervalSince(now)
        if seconds < 45 { return "now" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(max(1, minutes)) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if remainder == 0 { return "\(hours)h" }
        return "\(hours)h \(remainder)m"
    }

    private static func streetName(in instruction: String) -> String? {
        let lower = instruction.lowercased()
        let markers = [" onto ", " on ", " toward ", " towards "]
        for marker in markers {
            guard let range = lower.range(of: marker, options: .backwards) else { continue }
            let offset = lower.distance(from: lower.startIndex, to: range.upperBound)
            let start = instruction.index(instruction.startIndex, offsetBy: offset)
            var name = String(instruction[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let cut = name.range(of: " for ", options: .caseInsensitive) {
                name = String(name[..<cut.lowerBound])
            }
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
            if name.count >= 2 { return name }
        }
        return nil
    }

    private static func fallbackManeuver(from instruction: String) -> String {
        let lower = instruction.lowercased()
        if lower.contains("u-turn") || lower.contains("u turn") { return "U-turn" }
        if lower.contains("roundabout") || lower.contains("rotary") { return "Roundabout" }
        if lower.contains("destination") || lower.contains("arrive") { return "Destination" }
        if lower.contains("left") { return "Left" }
        if lower.contains("right") { return "Right" }
        if lower.contains("straight") || lower.contains("continue") { return "Straight" }
        return instruction
    }

    private static func clipped(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
