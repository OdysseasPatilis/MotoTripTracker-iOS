import MapKit
import SwiftUI
import UIKit

/// Lists nearby petrol stations ranked by brand / octane preferences, with Apple place details for hours.
struct PetrolStationsView: View {
    @Environment(AppContainer.self) private var app
    @Environment(ThemeStore.self) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var stations: [PetrolStationFinder.RankedStation] = []
    @State private var searchPlan: PetrolSearchPlan?
    @State private var isLoading = true
    @State private var detailItem: MKMapItem?

    private let finder = PetrolStationFinder()

    var body: some View {
        let colors = theme.palette

        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Finding stations…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if stations.isEmpty {
                    ContentUnavailableView(
                        "No stations nearby",
                        systemImage: "fuelpump",
                        description: Text(
                            "Try again when you have a GPS fix, or adjust Fuel preferences."
                        )
                    )
                } else {
                    List {
                        Section {
                            ForEach(stations) { station in
                                stationRow(station, colors: colors)
                            }
                        } header: {
                            if let searchPlan {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Recommended for you")
                                    Text(searchPlan.summary)
                                        .font(.caption)
                                        .foregroundStyle(colors.textSecondary)
                                    if searchPlan.prioritizeHighway {
                                        Text("Highway stations ranked first")
                                            .font(.caption2)
                                            .foregroundStyle(colors.neonBlue)
                                    }
                                }
                            } else {
                                Text("Recommended for you")
                            }
                        } footer: {
                            Text(
                                "Search radius adapts to your area — tighter in cities, wider in towns and rural areas. On the highway, stations on or beside the road are ranked first. Tap Details for Apple Maps hours before you go."
                            )
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(colors.bgDeep.ignoresSafeArea())
            .navigationTitle("Petrol")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .tint(colors.neonGreen)
                }
            }
            .mapItemDetailSheet(item: $detailItem, displaysMap: true)
            .task {
                await reload()
            }
        }
    }

    @ViewBuilder
    private func stationRow(_ station: PetrolStationFinder.RankedStation, colors: AppPalette) -> some View {
        let rec = station.recommendation
        let prefs = app.petrolPreferences

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(rec.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(colors.textPrimary)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        Text(formatDistance(rec.distanceMeters))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(colors.textSecondary)

                        openBadge(rec.openStatus, colors: colors)

                        if prefs.isPreferredBrand(rec.brand ?? rec.name) {
                            Text("Preferred")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(colors.neonGreen)
                        }

                        if rec.isHighwayAccessible {
                            Text("Highway")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(colors.neonBlue)
                        }
                    }

                    Text(rec.displayOctanes(preferred: prefs.preferredOctanes))
                        .font(.caption)
                        .foregroundStyle(octaneColor(rec, prefs: prefs, colors: colors))
                }

                Spacer(minLength: 8)

                VStack(spacing: 8) {
                    Button("Go") {
                        app.navigationService.setDestination(
                            coordinate: rec.coordinate,
                            name: rec.name
                        )
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(colors.neonGreen)
                    .controlSize(.small)

                    Button("Details") {
                        if let item = station.mapItem {
                            detailItem = item
                        } else {
                            let item = MKMapItem(placemark: MKPlacemark(coordinate: rec.coordinate))
                            item.name = rec.name
                            detailItem = item
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(colors.neonBlue)
                }
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(colors.bgCard)
        .opacity(rec.openStatus == .closed ? 0.55 : 1)
    }

    private func openBadge(_ status: OpeningHoursEvaluator.Status, colors: AppPalette) -> some View {
        let (text, color): (String, Color) = switch status {
        case .open: ("Open", colors.neonGreen)
        case .closed: ("Closed", colors.neonRed)
        case .unknown: ("Hours ?", colors.routeAmber)
        }
        return Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
    }

    private func octaneColor(
        _ rec: PetrolStationRecommendation,
        prefs: PetrolPreferences,
        colors: AppPalette
    ) -> Color {
        if rec.availableOctanes.isEmpty { return colors.textSecondary }
        if !rec.availableOctanes.isDisjoint(with: prefs.preferredOctanes) {
            return colors.neonGreen
        }
        return colors.routeAmber
    }

    private func formatDistance(_ meters: CLLocationDistance) -> String {
        if meters >= 1000 {
            return String(format: "%.1f km", meters / 1000)
        }
        return "\(Int(meters.rounded())) m"
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }

        guard let location = app.locationService.lastLocation else {
            stations = []
            searchPlan = nil
            return
        }

        let speedKmh = app.tripManager.sessionState.stats.speed
        let course = location.course >= 0 ? location.course : nil

        let result = await finder.search(
            near: location.coordinate,
            preferences: app.petrolPreferences,
            speedKmh: speedKmh,
            courseDegrees: course
        )
        searchPlan = result.plan
        stations = result.stations
    }
}
