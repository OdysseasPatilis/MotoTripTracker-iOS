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

        ZStack {
            colors.bgDeep.ignoresSafeArea()

            if let trip {
                VStack(spacing: 0) {
                    summaryTopBar(trip, colors: colors)

                    ScrollView {
                        VStack(spacing: 10) {
                            heroDate(trip, colors: colors)
                            mapPreviewCard(trip, colors: colors)
                            shareActions(trip, colors: colors)
                            statsGrid(trip, colors: colors)
                            momentsSection(colors: colors)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                        .padding(.bottom, 32)
                    }
                }
            } else {
                ProgressView()
                    .tint(colors.neonGreen)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
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

    private func summaryTopBar(_ trip: Trip, colors: AppPalette) -> some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "arrow.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(colors.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(colors.bgCard, in: Circle())
            }

            Spacer()

            Text("Ride Summary")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(colors.textPrimary)

            Spacer()

            Button {
                app.repository.toggleFavorite(id: tripID)
                reload()
            } label: {
                Image(systemName: trip.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(trip.isFavorite ? colors.routeAmber : colors.textMuted)
                    .frame(width: 36, height: 36)
                    .background(colors.bgCard, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Button { showRename = true } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(colors.textMuted)
                    .frame(width: 36, height: 36)
                    .background(colors.bgCard, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Button { showDeleteConfirm = true } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(colors.stopRed)
                    .frame(width: 36, height: 36)
                    .background(colors.deleteButtonBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func heroDate(_ trip: Trip, colors: AppPalette) -> some View {
        VStack(spacing: 4) {
            Text("DATE & TIME")
                .font(.system(size: 10, weight: .regular))
                .tracking(1.5)
                .foregroundStyle(colors.heroLabel)
            Text(trip.displayTitle)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(colors.mint)
                .multilineTextAlignment(.center)
            Text(RideFormatters.timestampToDate(trip.startTime))
                .font(.system(size: 13))
                .foregroundStyle(colors.mint.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(colors.heroGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func shareActions(_ trip: Trip, colors: AppPalette) -> some View {
        HStack(spacing: 10) {
            Button {
                RideShareHelper.shareCardImage(trip: trip, moments: moments)
            } label: {
                Label("Share card", systemImage: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .foregroundStyle(colors.textPrimary)
                    .background(colors.bgCard, in: Capsule())
            }

            Button {
                let points = app.repository.routePoints(for: trip.id)
                RideShareHelper.shareGPX(trip: trip, points: points)
            } label: {
                Label("GPX", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .foregroundStyle(colors.textPrimary)
                    .background(colors.bgCard, in: Capsule())
            }
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
                    .font(.system(size: 13))
                    .foregroundStyle(colors.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Text(String(format: "%.1f km", trip.distanceKm))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.75))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.55), in: Capsule())
                .padding(12)
        }
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(colors.borderSubtle, lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            NavigationLink(value: AppRoute.fullRoute(trip.id)) {
                Text("VIEW ROUTE")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Color(hex: 0x0A0A0F))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(colors.mint, in: Capsule())
            }
            .padding(12)
        }
    }

    private func statsGrid(_ trip: Trip, colors: AppPalette) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                SummaryStatCard(label: "DISTANCE", value: String(format: "%.1f", trip.distanceKm), unit: "km", colors: colors)
                SummaryStatCard(label: "TOTAL TIME", value: RideFormatters.secondsToTime(trip.totalTime), unit: "mm:ss", colors: colors)
            }
            HStack(spacing: 12) {
                SummaryStatCard(
                    label: "MOVING",
                    value: RideFormatters.secondsToTime(trip.movingTime),
                    unit: "mm:ss",
                    valueColor: colors.neonGreen,
                    colors: colors
                )
                SummaryStatCard(
                    label: "STOPPED",
                    value: RideFormatters.secondsToTime(trip.stoppedTime),
                    unit: "mm:ss",
                    valueColor: colors.neonRed,
                    colors: colors
                )
            }
            HStack(spacing: 12) {
                SummaryStatCard(label: "AVG SPEED", value: "\(Int(trip.avgSpeed))", unit: "km/h", colors: colors)
                SummaryStatCard(
                    label: "MAX SPEED",
                    value: "\(Int(trip.maxSpeed))",
                    unit: "km/h",
                    valueColor: colors.neonBlue,
                    colors: colors
                )
            }
            HStack(spacing: 12) {
                SummaryStatCard(label: "ELEVATION", value: "+\(Int(trip.elevationGain))", unit: "meters", colors: colors)
                SummaryStatCard(
                    label: "MAX G",
                    value: String(format: "%.2f", trip.maxGForce),
                    unit: "G-force",
                    valueColor: colors.neonGreen,
                    colors: colors
                )
            }
            HStack(spacing: 12) {
                SummaryStatCard(
                    label: "LATERAL G",
                    value: String(format: "%.2f", trip.maxLateralGForce),
                    unit: "G-force",
                    valueColor: colors.neonBlue,
                    colors: colors
                )
                SummaryStatCard(
                    label: "CORNERS",
                    value: "\(trip.cornerCount)",
                    unit: "turns",
                    valueColor: colors.neonGreen,
                    colors: colors
                )
            }
        }
    }

    @ViewBuilder
    private func momentsSection(colors: AppPalette) -> some View {
        if !moments.moments.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("RIDE MOMENTS")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(2)
                    .foregroundStyle(colors.textMuted)

                ForEach(moments.moments) { moment in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(moment.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(colors.textPrimary)
                            Text(moment.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(colors.textMuted)
                        }
                        Spacer()
                        Text(moment.value)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(colors.neonGreen)
                    }
                    .padding(14)
                    .background(colors.bgCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .padding(.top, 8)
        }
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

struct SummaryStatCard: View {
    let label: String
    let value: String
    let unit: String
    var valueColor: Color?
    let colors: AppPalette

    var body: some View {
        VStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .tracking(1)
                .foregroundStyle(colors.textMuted)
            Text(value)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(valueColor ?? colors.textPrimary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(unit)
                .font(.system(size: 12))
                .foregroundStyle(colors.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(colors.bgCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(colors.borderSubtle, lineWidth: 1)
        )
    }
}
