import Foundation

/// Evaluates common OpenStreetMap `opening_hours` values for "is open now?".
/// Covers 24/7, Mo–Su ranges, and simple day+time rules. Full OSM grammar is huge;
/// unknown / unsupported strings return `nil` so callers can treat them as unknown.
enum OpeningHoursEvaluator {
    enum Status: Equatable {
        case open
        case closed
        case unknown
    }

    /// Compact label for list UI (e.g. "24/7", "06:00–22:00").
    static func shortLabel(of raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        text = text.replacingOccurrences(of: "–", with: "-")
        let lowered = text.lowercased()
        if lowered == "24/7" || lowered == "open" { return "24/7" }
        if lowered == "closed" || lowered == "off" { return "Closed" }

        // Prefer the first time range in the string.
        if let match = text.range(
            of: #"\d{1,2}:\d{2}\s*-\s*\d{1,2}:\d{2}"#,
            options: .regularExpression
        ) {
            let range = String(text[match]).replacingOccurrences(of: " ", with: "")
            return range.replacingOccurrences(of: "-", with: "–")
        }
        if text.count <= 28 { return text }
        return String(text.prefix(25)) + "…"
    }

    static func status(of raw: String?, at date: Date = Date(), calendar: Calendar = .current) -> Status {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return .unknown
        }
        text = text.replacingOccurrences(of: "–", with: "-")

        let lowered = text.lowercased()
        if lowered == "24/7" || lowered == "open" { return .open }
        if lowered == "closed" || lowered == "off" { return .closed }

        // Split on `;` rules (last matching rule wins in OSM — we evaluate all and prefer open).
        let rules = text.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        var sawParsable = false
        var matchedOpen = false
        var matchedClosed = false

        for rule in rules {
            let ruleLower = rule.lowercased()
            if ruleLower == "24/7" {
                sawParsable = true
                matchedOpen = true
                continue
            }
            if ruleLower.hasSuffix(" off") || ruleLower == "off" || ruleLower == "closed" {
                if let days = parseDays(from: rule) {
                    sawParsable = true
                    if daysContains(days, date: date, calendar: calendar) {
                        matchedClosed = true
                        matchedOpen = false
                    }
                }
                continue
            }

            guard let parsed = parseDayTimeRule(rule) else { continue }
            sawParsable = true
            if daysContains(parsed.days, date: date, calendar: calendar),
               timeInRange(parsed.openMinutes, parsed.closeMinutes, date: date, calendar: calendar) {
                matchedOpen = true
                matchedClosed = false
            }
        }

        if !sawParsable { return .unknown }
        if matchedOpen { return .open }
        if matchedClosed { return .closed }
        // Had parsable rules but none matched today → closed for this moment.
        return .closed
    }

    // MARK: - Parsing

    private struct DayTimeRule {
        let days: Set<Int> // Calendar weekday 1=Sun ... 7=Sat
        let openMinutes: Int
        let closeMinutes: Int
    }

    private static let dayMap: [String: Int] = [
        "su": 1, "mo": 2, "tu": 3, "we": 4, "th": 5, "fr": 6, "sa": 7
    ]

    private static func parseDayTimeRule(_ rule: String) -> DayTimeRule? {
        // Examples: "Mo-Su 06:00-22:00", "Mo-Fr 08:00-20:00", "Sa 09:00-14:00"
        let parts = rule.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let days = parseDays(from: parts[0]),
              let times = parseTimeRange(parts[1]) else { return nil }
        return DayTimeRule(days: days, openMinutes: times.0, closeMinutes: times.1)
    }

    private static func parseDays(from fragment: String) -> Set<Int>? {
        let token = fragment
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .split(separator: " ")
            .first
            .map(String.init) ?? fragment.lowercased()

        // Strip trailing "off" if present: "Mo-Su off"
        let cleaned = token.replacingOccurrences(of: "off", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        if cleaned.isEmpty { return nil }

        if cleaned.contains("-") {
            let ends = cleaned.split(separator: "-").map(String.init)
            guard ends.count == 2,
                  let start = dayMap[String(ends[0].prefix(2))],
                  let end = dayMap[String(ends[1].prefix(2))] else { return nil }
            return weekdayRange(from: start, to: end)
        }

        // Comma list: Mo,We,Fr
        if cleaned.contains(",") {
            var set = Set<Int>()
            for part in cleaned.split(separator: ",") {
                guard let day = dayMap[String(part.prefix(2))] else { return nil }
                set.insert(day)
            }
            return set
        }

        guard let day = dayMap[String(cleaned.prefix(2))] else { return nil }
        return [day]
    }

    private static func weekdayRange(from start: Int, to end: Int) -> Set<Int> {
        var set = Set<Int>()
        var day = start
        for _ in 0..<7 {
            set.insert(day)
            if day == end { break }
            day = day == 7 ? 1 : day + 1
        }
        return set
    }

    private static func parseTimeRange(_ text: String) -> (Int, Int)? {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
        let parts = cleaned.split(separator: "-").map(String.init)
        guard parts.count == 2,
              let open = parseHHMM(parts[0]),
              let close = parseHHMM(parts[1]) else { return nil }
        return (open, close)
    }

    private static func parseHHMM(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count >= 2,
              let h = Int(parts[0]),
              let m = Int(parts[1]),
              (0...48).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    private static func daysContains(_ days: Set<Int>, date: Date, calendar: Calendar) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        return days.contains(weekday)
    }

    private static func timeInRange(_ open: Int, _ close: Int, date: Date, calendar: Calendar) -> Bool {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let now = hour * 60 + minute
        if close > open {
            return now >= open && now < close
        }
        // Overnight range, e.g. 22:00-06:00
        return now >= open || now < close
    }
}
