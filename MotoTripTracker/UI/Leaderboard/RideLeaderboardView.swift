import SwiftUI

enum LeaderboardCategory: String, CaseIterable, Identifiable {
    case speed = "Speed"
    case distance = "Distance"
    case turns = "Turns"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .speed: "gauge.with.dots.needle.67percent"
        case .distance: "point.bottomleft.forward.to.point.topright.scurvepath"
        case .turns: "arrow.triangle.turn.up.right.diamond"
        }
    }

    var unitHint: String {
        switch self {
        case .speed: "km/h"
        case .distance: "km"
        case .turns: "corners"
        }
    }

    func value(for trip: Trip) -> Double {
        switch self {
        case .speed: trip.maxSpeed
        case .distance: trip.distanceKm
        case .turns: Double(trip.cornerCount)
        }
    }

    func isEligible(_ trip: Trip) -> Bool {
        value(for: trip) > 0
    }

    func formattedValue(for trip: Trip) -> String {
        switch self {
        case .speed:
            return "\(Int(trip.maxSpeed)) km/h"
        case .distance:
            return String(format: "%.1f km", trip.distanceKm)
        case .turns:
            return "\(trip.cornerCount)"
        }
    }
}

struct LeaderboardEntry: Identifiable {
    let rank: Int
    let trip: Trip

    var id: UUID { trip.id }
}

enum LeaderboardRanking {
    static func entries(from trips: [Trip], category: LeaderboardCategory) -> [LeaderboardEntry] {
        let sorted = trips
            .filter(category.isEligible)
            .sorted { lhs, rhs in
                let lv = category.value(for: lhs)
                let rv = category.value(for: rhs)
                if lv == rv {
                    return lhs.startTime > rhs.startTime
                }
                return lv > rv
            }

        return sorted.enumerated().map { index, trip in
            LeaderboardEntry(rank: index + 1, trip: trip)
        }
    }
}

struct RideLeaderboardView: View {
    @Environment(AppContainer.self) private var app
    @Environment(ThemeStore.self) private var theme

    @State private var trips: [Trip] = []
    @State private var category: LeaderboardCategory = .speed

    private var entries: [LeaderboardEntry] {
        LeaderboardRanking.entries(from: trips, category: category)
    }

    var body: some View {
        let colors = theme.palette

        List {
            Section {
                Picker("Category", selection: $category) {
                    ForEach(LeaderboardCategory.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
            }

            if entries.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Rankings Yet",
                        systemImage: category.systemImage,
                        description: Text("Complete a few rides to fill the \(category.rawValue.lowercased()) leaderboard.")
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(entries) { entry in
                        NavigationLink(value: AppRoute.summary(entry.trip.id)) {
                            LeaderboardRow(
                                entry: entry,
                                category: category,
                                colors: colors
                            )
                        }
                    }
                } header: {
                    Text("Top \(category.rawValue)")
                } footer: {
                    Text("Tap a ride to open its summary.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(colors.bgDeep.ignoresSafeArea())
        .navigationTitle("Leaderboard")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            trips = app.repository.allTrips()
        }
    }
}

private struct LeaderboardRow: View {
    let entry: LeaderboardEntry
    let category: LeaderboardCategory
    let colors: AppPalette

    var body: some View {
        HStack(spacing: 14) {
            rankBadge

            VStack(alignment: .leading, spacing: 3) {
                Text(category.formattedValue(for: entry.trip))
                    .font(.headline)
                    .foregroundStyle(colors.textPrimary)
                Text(entry.trip.displayTitle)
                    .font(.subheadline)
                    .foregroundStyle(colors.textSecondary)
                    .lineLimit(1)
                Text(RideFormatters.timestampToDate(entry.trip.startTime))
                    .font(.caption)
                    .foregroundStyle(colors.textMuted)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var rankBadge: some View {
        Text("\(entry.rank)")
            .font(.headline.monospacedDigit())
            .foregroundStyle(rankForeground)
            .frame(width: 36, height: 36)
            .background(rankBackground, in: Circle())
            .accessibilityLabel("Rank \(entry.rank)")
    }

    private var rankForeground: Color {
        switch entry.rank {
        case 1, 2, 3: Color(hex: 0x0A0A0F)
        default: colors.textPrimary
        }
    }

    private var rankBackground: Color {
        switch entry.rank {
        case 1: colors.routeAmber
        case 2: Color(hex: 0xC0C0C0)
        case 3: Color(hex: 0xCD7F32)
        default: colors.bgPanel
        }
    }
}
