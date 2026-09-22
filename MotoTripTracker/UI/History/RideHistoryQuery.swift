import Foundation

struct RideHistoryFilter {
    var tab: RideHistoryTab = .all
    var searchQuery: String = ""
    var datePreset: DateFilterPreset = .any
    var customFrom: Date = Date()
    var customTo: Date = Date()
}

struct RideDaySection: Identifiable {
    let id: Date
    let title: String
    let rides: [Trip]
}

enum RideHistoryQuery {
    static func visibleRides(
        _ rides: [Trip],
        filter: RideHistoryFilter,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Trip] {
        var scoped = rides
        if filter.tab == .favorites {
            scoped = scoped.filter(\.isFavorite)
        }
        scoped = scoped.filter { matchesDate($0, filter: filter, now: now, calendar: calendar) }

        let query = filter.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return scoped }
        return scoped.filter {
            $0.displayTitle.lowercased().contains(query)
                || RideFormatters.timestampToDate($0.startTime).lowercased().contains(query)
        }
    }

    static func daySections(
        from rides: [Trip],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [RideDaySection] {
        let grouped = Dictionary(grouping: rides) { trip in
            calendar.startOfDay(for: Date(timeIntervalSince1970: trip.startTime))
        }
        return grouped.keys.sorted(by: >).map { dayStart in
            let dayRides = (grouped[dayStart] ?? []).sorted { $0.startTime > $1.startTime }
            return RideDaySection(
                id: dayStart,
                title: daySectionTitle(for: dayStart, now: now, calendar: calendar),
                rides: dayRides
            )
        }
    }

    private static func matchesDate(
        _ ride: Trip,
        filter: RideHistoryFilter,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        let date = Date(timeIntervalSince1970: ride.startTime)

        switch filter.datePreset {
        case .any:
            return true
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .yesterday:
            let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
            return calendar.isDate(date, inSameDayAs: yesterday)
        case .thisWeek:
            return calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear)
        case .thisMonth:
            return calendar.isDate(date, equalTo: now, toGranularity: .month)
        case .custom:
            let start = calendar.startOfDay(for: min(filter.customFrom, filter.customTo))
            let end = endOfDay(max(filter.customFrom, filter.customTo), calendar: calendar)
            return date >= start && date <= end
        }
    }

    private static func daySectionTitle(for dayStart: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(dayStart, inSameDayAs: now) {
            return "Today"
        }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        if calendar.isDate(dayStart, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "dd/MM/yyyy"
        return formatter.string(from: dayStart)
    }

    static func endOfDay(_ date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? date
    }
}
