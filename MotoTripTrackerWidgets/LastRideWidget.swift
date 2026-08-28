import SwiftUI
import WidgetKit

struct LastRideEntry: TimelineEntry {
    let date: Date
    let snapshot: RideWidgetSnapshot
}

struct LastRideProvider: TimelineProvider {
    func placeholder(in context: Context) -> LastRideEntry {
        LastRideEntry(
            date: Date(),
            snapshot: RideWidgetSnapshot(
                lastRideTitle: "Sunday twisties",
                lastRideDistanceKm: 42.5,
                lastRideMaxSpeedKmh: 118,
                lastRideCornerCount: 37,
                lastRideDate: Date(),
                weekRideCount: 3,
                weekDistanceKm: 120,
                weekMaxSpeedKmh: 130,
                weekCornerCount: 90,
                updatedAt: Date()
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (LastRideEntry) -> Void) {
        completion(LastRideEntry(date: Date(), snapshot: RideWidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LastRideEntry>) -> Void) {
        let entry = LastRideEntry(date: Date(), snapshot: RideWidgetSnapshot.load())
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date().addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct LastRideWidget: Widget {
    let kind = "LastRideWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LastRideProvider()) { entry in
            LastRideWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetBrand.bgDeep
                }
        }
        .configurationDisplayName("Last Ride")
        .description("Distance, max speed, and corners from your most recent ride.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct LastRideWidgetView: View {
    let entry: LastRideEntry

    var body: some View {
        if let km = entry.snapshot.lastRideDistanceKm {
            VStack(alignment: .leading, spacing: 8) {
                Text("LAST RIDE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(WidgetBrand.neonGreen)
                    .tracking(0.6)

                Text(entry.snapshot.lastRideTitle ?? "Ride")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer(minLength: 0)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%.1f", km))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("km")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(WidgetBrand.textSecondary)
                }

                HStack(spacing: 12) {
                    if let max = entry.snapshot.lastRideMaxSpeedKmh {
                        Label("\(Int(max)) km/h", systemImage: "gauge.with.dots.needle.67percent")
                    }
                    if let corners = entry.snapshot.lastRideCornerCount {
                        Label("\(corners)", systemImage: "arrow.triangle.turn.up.right.diamond")
                    }
                }
                .font(.caption2)
                .foregroundStyle(WidgetBrand.textSecondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("LAST RIDE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(WidgetBrand.neonGreen)
                Text("No rides yet")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Start a ride in MotoTripTracker to see stats here.")
                    .font(.caption)
                    .foregroundStyle(WidgetBrand.textSecondary)
                Spacer(minLength: 0)
            }
        }
    }
}
