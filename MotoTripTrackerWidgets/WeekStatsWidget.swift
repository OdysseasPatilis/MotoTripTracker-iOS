import SwiftUI
import WidgetKit

struct WeekStatsEntry: TimelineEntry {
    let date: Date
    let snapshot: RideWidgetSnapshot
}

struct WeekStatsProvider: TimelineProvider {
    func placeholder(in context: Context) -> WeekStatsEntry {
        WeekStatsEntry(
            date: Date(),
            snapshot: RideWidgetSnapshot(
                lastRideTitle: nil,
                lastRideDistanceKm: nil,
                lastRideMaxSpeedKmh: nil,
                lastRideCornerCount: nil,
                lastRideDate: nil,
                weekRideCount: 4,
                weekDistanceKm: 186.2,
                weekMaxSpeedKmh: 142,
                weekCornerCount: 128,
                updatedAt: Date()
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (WeekStatsEntry) -> Void) {
        completion(WeekStatsEntry(date: Date(), snapshot: RideWidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WeekStatsEntry>) -> Void) {
        let entry = WeekStatsEntry(date: Date(), snapshot: RideWidgetSnapshot.load())
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date().addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct WeekStatsWidget: Widget {
    let kind = "WeekStatsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WeekStatsProvider()) { entry in
            WeekStatsWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetBrand.bgDeep
                }
        }
        .configurationDisplayName("This Week")
        .description("Rides, distance, and corners for the current week.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct WeekStatsWidgetView: View {
    let entry: WeekStatsEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("THIS WEEK")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(WidgetBrand.neonBlue)
                .tracking(0.6)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.0f", entry.snapshot.weekDistanceKm))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("km")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(WidgetBrand.textSecondary)
            }

            Spacer(minLength: 0)

            HStack(spacing: 14) {
                metric("\(entry.snapshot.weekRideCount)", label: "rides")
                metric("\(Int(entry.snapshot.weekMaxSpeedKmh))", label: "max")
                metric("\(entry.snapshot.weekCornerCount)", label: "corners")
            }
        }
    }

    private func metric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
            Text(label)
                .font(.caption2)
                .foregroundStyle(WidgetBrand.textSecondary)
        }
    }
}
