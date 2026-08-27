import CoreLocation
import MapKit
import SwiftUI

struct RideSummaryView: View {
    @Environment(AppContainer.self) private var app
    @Environment(ThemeStore.self) private var theme
    @Environment(\.dismiss) private var dismiss

    let tripID: UUID
    @State private var trip: Trip?
    @State private var moments: RideMoments = RideMoments(moments: [])
    @State private var showDeleteConfirm = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var mapPosition: MapCameraPosition = .automatic

    var body: some View {
        let colors = theme.palette

        Group {
            if let trip {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(trip.displayTitle)
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(colors.textPrimary)
                            Text(RideFormatters.timestampToDate(trip.startTime))
                                .font(.subheadline)
                                .foregroundStyle(colors.textSecondary)
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(Color.clear)
                    }

                    Section {
                        mapPreviewCard(trip, colors: colors)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            .listRowBackground(Color.clear)
                    }

                    Section("Stats") {
                        summaryRow("Distance", String(format: "%.1f km", trip.distanceKm), colors: colors)
                        summaryRow("Total time", RideFormatters.secondsToTime(trip.totalTime), colors: colors)
                        summaryRow("Moving", RideFormatters.secondsToTime(trip.movingTime), valueColor: colors.neonGreen, colors: colors)
                        summaryRow("Stopped", RideFormatters.secondsToTime(trip.stoppedTime), valueColor: colors.neonRed, colors: colors)
                        summaryRow("Avg speed", "\(Int(trip.avgSpeed)) km/h", colors: colors)
                        summaryRow("Max speed", "\(Int(trip.maxSpeed)) km/h", valueColor: colors.neonBlue, colors: colors)
                        summaryRow("Elevation", "+\(Int(trip.elevationGain)) m", colors: colors)
                        summaryRow("Max G", String(format: "%.2f G", trip.maxGForce), valueColor: colors.neonGreen, colors: colors)
                        summaryRow("Lateral G", String(format: "%.2f G", trip.maxLateralGForce), valueColor: colors.neonBlue, colors: colors)
                        summaryRow("Corners", "\(trip.cornerCount)", valueColor: colors.neonGreen, colors: colors)
                    }

                    if !moments.moments.isEmpty {
                        Section {
                            ForEach(moments.moments) { moment in
                                MomentRow(moment: moment, colors: colors)
                            }
                        } header: {
                            Text("Moments")
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            } else {
                ProgressView()
                    .tint(colors.neonGreen)
            }
        }
        .background(colors.bgDeep.ignoresSafeArea())
        .navigationTitle("Summary")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let trip {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        app.repository.toggleFavorite(id: tripID)
                        reload()
                    } label: {
                        Image(systemName: trip.isFavorite ? "star.fill" : "star")
                    }
                    .accessibilityLabel(trip.isFavorite ? "Remove favorite" : "Add favorite")

                    Menu {
                        Button {
                            RideShareHelper.shareCardImage(trip: trip, moments: moments)
                        } label: {
                            Label("Share Card", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            let points = app.repository.routePoints(for: trip.id)
                            RideShareHelper.shareGPX(trip: trip, points: points)
                        } label: {
                            Label("Export GPX", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        }
                        Button {
                            showRename = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        NavigationLink(value: AppRoute.fullRoute(trip.id)) {
                            Label("View Route", systemImage: "map")
                        }
                        Divider()
                        Button("Delete Ride", role: .destructive) {
                            showDeleteConfirm = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .onAppear { reload() }
        .confirmationDialog("Delete this ride?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                app.repository.deleteTrip(id: tripID)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename ride", isPresented: $showRename) {
            TextField("Title", text: $renameText)
            Button("Save") {
                app.repository.renameTrip(id: tripID, title: renameText)
                reload()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func reload() {
        trip = app.repository.fetchTrip(id: tripID)
        if let trip {
            let points = app.repository.routePoints(for: tripID)
            moments = RideMomentsCalculator.calculate(trip: trip, points: points)
            renameText = trip.title ?? ""
        }
    }

    private func summaryRow(
        _ label: String,
        _ value: String,
        valueColor: Color? = nil,
        colors: AppPalette
    ) -> some View {
        LabeledContent {
            Text(value)
                .foregroundStyle(valueColor ?? colors.textPrimary)
                .fontWeight(.semibold)
        } label: {
            Text(label)
                .foregroundStyle(colors.textPrimary)
        }
    }

    @ViewBuilder
    private func mapPreviewCard(_ trip: Trip, colors: AppPalette) -> some View {
        let coords = routeCoordinates(for: trip)

        ZStack(alignment: .bottomLeading) {
            if coords.count >= 2 {
                Map(position: $mapPosition) {
                    MapPolyline(coordinates: coords)
                        .stroke(
                            LinearGradient(
                                colors: [colors.mint, colors.neonBlue],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                        )
                    if let first = coords.first {
                        Annotation("", coordinate: first) {
                            Circle()
                                .fill(colors.mint)
                                .frame(width: 10, height: 10)
                                .overlay(Circle().stroke(colors.bgDeep, lineWidth: 2))
                        }
                    }
                    if let last = coords.last {
                        Annotation("", coordinate: last) {
                            Circle()
                                .fill(colors.stopRed)
                                .frame(width: 10, height: 10)
                                .overlay(Circle().stroke(colors.bgDeep, lineWidth: 2))
                        }
                    }
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll))
                .disabled(true)
                .onAppear {
                    if let region = Self.region(fitting: coords) {
                        mapPosition = .region(region)
                    }
                }
            } else {
                colors.mapCardBg
                Text("No route data")
                    .font(.subheadline)
                    .foregroundStyle(colors.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Text(String(format: "%.1f km", trip.distanceKm))
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(12)
        }
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func routeCoordinates(for trip: Trip) -> [CLLocationCoordinate2D] {
        if let encoded = trip.encodedRoutePolyline, !encoded.isEmpty {
            return PolylineEncoder.decode(encoded).map {
                CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
            }
        }
        return app.repository.routePoints(for: trip.id).map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
    }

    private static func region(fitting coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard !coordinates.isEmpty else { return nil }
        var minLat = coordinates[0].latitude
        var maxLat = coordinates[0].latitude
        var minLng = coordinates[0].longitude
        var maxLng = coordinates[0].longitude
        for c in coordinates {
            minLat = min(minLat, c.latitude)
            maxLat = max(maxLat, c.latitude)
            minLng = min(minLng, c.longitude)
            maxLng = max(maxLng, c.longitude)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: (minLng + maxLng) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.45, 0.01),
                longitudeDelta: max((maxLng - minLng) * 1.45, 0.01)
            )
        )
    }
}

private struct MomentRow: View {
    let moment: RideMoment
    let colors: AppPalette

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: moment.systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(colors.neonGreen)
                .frame(width: 36, height: 36)
                .background(colors.neonGreen.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(moment.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(colors.textPrimary)
                    Spacer(minLength: 8)
                    Text(moment.value)
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(colors.neonBlue)
                }
                Text(moment.detail)
                    .font(.caption)
                    .foregroundStyle(colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(moment.title), \(moment.value), \(moment.detail)")
    }
}
