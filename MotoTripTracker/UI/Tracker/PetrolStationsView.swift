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
                                stationCard(station, colors: colors)
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
                                "Open/closed uses OpenStreetMap hours when available. Stars show how well a station matches your brand and octane prefs — Apple Maps ratings aren’t readable by apps. Tap Details for Apple’s full place card."
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
    private func stationCard(_ station: PetrolStationFinder.RankedStation, colors: AppPalette) -> some View {
        let rec = station.recommendation
        let prefs = app.petrolPreferences
        let stars = rec.preferenceMatchStars(preferences: prefs)
        let address = station.mapItem?.placemark.thoroughfare
            ?? station.mapItem?.placemark.locality

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                brandGlyph(rec, colors: colors)

                VStack(alignment: .leading, spacing: 6) {
                    Text(rec.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(colors.textPrimary)
                        .lineLimit(2)

                    if let address, !address.isEmpty {
                        Text(address)
                            .font(.caption)
                            .foregroundStyle(colors.textSecondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 8) {
                        Label(formatDistance(rec.distanceMeters), systemImage: "location.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(colors.textSecondary)
                            .labelStyle(.titleAndIcon)

                        matchStars(stars, colors: colors)
                    }

                    openStatusRow(rec, colors: colors)

                    HStack(spacing: 6) {
                        if prefs.isPreferredBrand(rec.brand ?? rec.name) {
                            chip("Preferred", tint: colors.neonGreen, colors: colors)
                        }
                        if rec.isHighwayAccessible {
                            chip("Highway", tint: colors.neonBlue, colors: colors)
                        }
                        octaneChip(rec, prefs: prefs, colors: colors)
                    }
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button {
                    app.navigationService.setDestination(
                        coordinate: rec.coordinate,
                        name: rec.name
                    )
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    dismiss()
                } label: {
                    Text("Go")
                        .font(.subheadline.weight(.bold))
                        .frame(minWidth: 72)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(colors.neonGreen)
                .controlSize(.regular)

                Button {
                    if let item = station.mapItem {
                        detailItem = item
                    } else {
                        let item = MKMapItem(placemark: MKPlacemark(coordinate: rec.coordinate))
                        item.name = rec.name
                        detailItem = item
                    }
                } label: {
                    Text("Details")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(colors.neonBlue)
            }
        }
        .padding(.vertical, 8)
        .listRowBackground(colors.bgCard)
        .opacity(rec.openStatus == .closed ? 0.55 : 1)
    }

    private func brandGlyph(_ rec: PetrolStationRecommendation, colors: AppPalette) -> some View {
        let letter = String((rec.brand ?? rec.name).prefix(1)).uppercased()
        return ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(colors.neonBlue.opacity(0.16))
                .frame(width: 48, height: 48)
            if letter.isEmpty {
                Image(systemName: "fuelpump.fill")
                    .foregroundStyle(colors.neonBlue)
            } else {
                Text(letter)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(colors.neonBlue)
            }
        }
    }

    private func matchStars(_ count: Int, colors: AppPalette) -> some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { index in
                Image(systemName: index <= count ? "star.fill" : "star")
                    .font(.caption2)
                    .foregroundStyle(index <= count ? colors.routeAmber : colors.textSecondary.opacity(0.35))
            }
        }
        .accessibilityLabel("Preference match \(count) of 5 stars")
    }

    private func openStatusRow(_ rec: PetrolStationRecommendation, colors: AppPalette) -> some View {
        let (title, tint, icon): (String, Color, String) = switch rec.openStatus {
        case .open: ("Open now", colors.neonGreen, "checkmark.circle.fill")
        case .closed: ("Closed now", colors.neonRed, "xmark.circle.fill")
        case .unknown: ("Hours unknown", colors.routeAmber, "clock")
        }

        return HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
            Text(title)
                .font(.caption.weight(.bold))
            if let hours = rec.hoursSummary, rec.openStatus != .unknown {
                Text("·")
                    .foregroundStyle(colors.textSecondary)
                Text(hours)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(colors.textSecondary)
                    .lineLimit(1)
            } else if rec.openStatus == .unknown {
                Text("·")
                    .foregroundStyle(colors.textSecondary)
                Text("Check Details")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(colors.textSecondary)
            }
        }
        .foregroundStyle(tint)
    }

    private func chip(_ title: String, tint: Color, colors: AppPalette) -> some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
    }

    private func octaneChip(
        _ rec: PetrolStationRecommendation,
        prefs: PetrolPreferences,
        colors: AppPalette
    ) -> some View {
        let label = rec.displayOctanes(preferred: prefs.preferredOctanes)
        let tint = octaneColor(rec, prefs: prefs, colors: colors)
        return Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
            .lineLimit(1)
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
