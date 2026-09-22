import Foundation
import Testing
@testable import MotoTripTracker

struct RideHistoryQueryTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 15))!
    }

    @Test func favoritesTabHidesNonFavorites() {
        let favorite = trip(title: "Coast", start: now, favorite: true)
        let other = trip(title: "City", start: now, favorite: false)
        let visible = RideHistoryQuery.visibleRides(
            [favorite, other],
            filter: RideHistoryFilter(tab: .favorites),
            now: now,
            calendar: calendar
        )
        #expect(visible.map(\.title) == ["Coast"])
    }

    @Test func searchMatchesTitleIgnoringCase() {
        let coast = trip(title: "Coast Loop", start: now)
        let city = trip(title: "City Commute", start: now)
        let visible = RideHistoryQuery.visibleRides(
            [coast, city],
            filter: RideHistoryFilter(searchQuery: "  coast "),
            now: now,
            calendar: calendar
        )
        #expect(visible.map(\.title) == ["Coast Loop"])
    }

    @Test func todayPresetKeepsOnlyRidesFromToday() {
        let today = trip(title: "Today", start: now)
        let yesterday = trip(title: "Yesterday", start: now.addingTimeInterval(-86_400))
        let visible = RideHistoryQuery.visibleRides(
            [today, yesterday],
            filter: RideHistoryFilter(datePreset: .today),
            now: now,
            calendar: calendar
        )
        #expect(visible.map(\.title) == ["Today"])
    }

    @Test func groupsDaysNewestFirstWithTodayAndYesterdayTitles() {
        let morning = trip(title: "Morning", start: now.addingTimeInterval(-3_600))
        let afternoon = trip(title: "Afternoon", start: now)
        let yesterday = trip(title: "Yesterday", start: now.addingTimeInterval(-86_400))
        let older = trip(
            title: "Older",
            start: calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 8))!
        )

        let sections = RideHistoryQuery.daySections(
            from: [yesterday, afternoon, older, morning],
            now: now,
            calendar: calendar
        )

        #expect(sections.map(\.title) == ["Today", "Yesterday", "10/09/2026"])
        #expect(sections[0].rides.map(\.title) == ["Afternoon", "Morning"])
        #expect(sections[1].rides.map(\.title) == ["Yesterday"])
    }

    private func trip(title: String, start: Date, favorite: Bool = false) -> Trip {
        Trip(startTime: start.timeIntervalSince1970, title: title, isFavorite: favorite)
    }
}
