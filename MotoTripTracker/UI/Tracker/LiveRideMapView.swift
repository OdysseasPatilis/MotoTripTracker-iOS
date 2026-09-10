import CoreLocation
import MapKit
import SwiftUI

/// Live, videogame-style map for the ride dashboard.
///
/// While following the rider, the camera tracks GPS (3D + speed zoom when riding,
/// gentler top-down when idle). Panning or zooming pauses follow; a Recenter
/// button restores it. Draws the traveled trail, planned navigation route,
/// traffic cameras, and a destination pin.
struct LiveRideMapView: View {
    @Environment(AppContainer.self) private var app
    @Environment(ThemeStore.self) private var theme

    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var isFollowingUser = true
    /// Counts programmatic camera moves so `onMapCameraChange` does not treat them as user pans.
    @State private var programmaticCameraTokens = 0

    private var isRiding: Bool {
        let session = app.tripManager.sessionState
        return session.isActive && !session.isPaused
    }

    var body: some View {
        let colors = theme.palette
        let navigation = app.navigationService
        let traveled = app.tripManager.routeCoordinates
        let destination = navigation.destinationCoordinate
        let previewItems = Self.previewPolylineItems(from: navigation)
        let showRecenter = !isFollowingUser && navigation.phase != .previewing

        Map(position: $cameraPosition) {
            UserAnnotation()
            routeOverlays(
                previewItems: previewItems,
                activeRoute: navigation.phase == .previewing ? [] : navigation.routeCoordinates,
                traveled: traveled,
                routeColor: colors.neonBlue,
                trailColor: colors.mint
            )
            if let destination {
                destinationAnnotation(coordinate: destination, color: colors.neonBlue)
            }
            cameraAnnotations(
                cameras: app.trafficCameraService.nearbyCameras,
                speedColor: colors.routeAmber,
                redLightColor: colors.neonBlue
            )
        }
        // Realistic elevation is expensive on first load; keep it for active rides only.
        .mapStyle(
            .standard(
                elevation: isRiding ? .realistic : .flat,
                pointsOfInterest: .excludingAll,
                showsTraffic: true
            )
        )
        .mapControls {
            MapCompass()
        }
        .overlay(alignment: .bottomTrailing) {
            if showRecenter {
                Button {
                    recenterOnUser()
                } label: {
                    Image(systemName: "location.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(colors.neonBlue)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Recenter map on my location")
                .padding(.trailing, 12)
                // Sit above the idle search/petrol row (and other bottom map overlays).
                .padding(.bottom, 100)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showRecenter)
        .onMapCameraChange(frequency: .onEnd) { _ in
            if programmaticCameraTokens > 0 {
                programmaticCameraTokens -= 1
                return
            }
            guard app.navigationService.phase != .previewing else { return }
            if isFollowingUser {
                isFollowingUser = false
            }
        }
        .onAppear {
            if navigation.phase == .previewing {
                fitPreviewRoute()
            } else if isFollowingUser {
                updateCamera(location: app.locationService.lastLocation)
            }
        }
        .onChange(of: app.locationService.updateTick) { _, _ in
            guard isFollowingUser else { return }
            updateCamera(location: app.locationService.lastLocation)
        }
        .onChange(of: isRiding) { _, _ in
            guard isFollowingUser else { return }
            updateCamera(location: app.locationService.lastLocation)
        }
        .onChange(of: navigation.phase) { oldPhase, newPhase in
            if newPhase == .previewing {
                isFollowingUser = false
            } else if oldPhase == .previewing {
                isFollowingUser = true
                updateCamera(location: app.locationService.lastLocation)
            }
        }
        .onChange(of: navigation.previewRoutes.count) { oldCount, newCount in
            guard oldCount == 0, newCount > 0 else { return }
            fitPreviewRoute()
        }
        .onChange(of: navigation.selectedRouteID) { _, _ in
            fitPreviewRoute()
        }
    }

    /// MapPolyline caches stroke by content id; bake selection into `id` so
    /// highlight updates, and keep the selected route last for z-order.
    private static func previewPolylineItems(from navigation: NavigationService) -> [PreviewPolylineItem] {
        guard navigation.phase == .previewing else { return [] }
        let selectedID = navigation.selectedRouteID
        let alternates = navigation.previewRoutes
            .filter { $0.id != selectedID }
            .map { PreviewPolylineItem(id: "preview-alt-\($0.id)", coordinates: $0.coordinates, isSelected: false) }
        let selected = navigation.previewRoutes
            .filter { $0.id == selectedID }
            .map { PreviewPolylineItem(id: "preview-selected-\($0.id)", coordinates: $0.coordinates, isSelected: true) }
        return alternates + selected
    }

    @MapContentBuilder
    private func routeOverlays(
        previewItems: [PreviewPolylineItem],
        activeRoute: [CLLocationCoordinate2D],
        traveled: [CLLocationCoordinate2D],
        routeColor: Color,
        trailColor: Color
    ) -> some MapContent {
        ForEach(previewItems) { item in
            MapPolyline(coordinates: item.coordinates)
                .stroke(
                    routeColor.opacity(item.isSelected ? 1 : 0.35),
                    style: StrokeStyle(
                        lineWidth: item.isSelected ? 6 : 4,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
        }

        if previewItems.isEmpty, activeRoute.count > 1 {
            MapPolyline(coordinates: activeRoute)
                .stroke(
                    routeColor,
                    style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
                )
        }

        if traveled.count > 1 {
            MapPolyline(coordinates: traveled)
                .stroke(
                    trailColor,
                    style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                )
        }
    }

    @MapContentBuilder
    private func destinationAnnotation(coordinate: CLLocationCoordinate2D, color: Color) -> some MapContent {
        Annotation("Destination", coordinate: coordinate) {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 28, height: 28)
                Image(systemName: "flag.checkered")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
            }
        }
    }

    @MapContentBuilder
    private func cameraAnnotations(
        cameras: [TrafficCamera],
        speedColor: Color,
        redLightColor: Color
    ) -> some MapContent {
        ForEach(cameras) { camera in
            Annotation(camera.kind == .speed ? "Speed camera" : "Red light camera", coordinate: camera.coordinate) {
                ZStack {
                    Circle()
                        .fill(camera.kind == .speed ? speedColor : redLightColor)
                        .frame(width: 22, height: 22)
                    Image(systemName: camera.kind == .speed ? "camera.fill" : "trafficlight.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private func recenterOnUser() {
        isFollowingUser = true
        updateCamera(location: app.locationService.lastLocation)
    }

    private func updateCamera(location: CLLocation?) {
        guard app.navigationService.phase != .previewing else { return }
        guard isFollowingUser else { return }
        guard let location else { return }

        let camera: MapCamera
        if isRiding {
            let speedKmh = max(location.speed, 0) * 3.6
            // Pull the camera back as speed increases for a racing-game feel.
            let distance = 350.0 + min(speedKmh, 180) * 7.0
            let heading = location.course >= 0 ? location.course : 0
            camera = MapCamera(
                centerCoordinate: location.coordinate,
                distance: distance,
                heading: heading,
                pitch: 55
            )
        } else {
            camera = MapCamera(
                centerCoordinate: location.coordinate,
                distance: 1400,
                heading: 0,
                pitch: 0
            )
        }

        programmaticCameraTokens += 1
        withAnimation(.easeInOut(duration: 0.45)) {
            cameraPosition = .camera(camera)
        }
    }

    private func fitPreviewRoute() {
        let navigation = app.navigationService
        guard navigation.phase == .previewing,
              let coordinates = navigation.selectedPreviewRoute?.coordinates,
              coordinates.count > 1 else { return }

        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        let bounds = polyline.boundingMapRect
        let horizontalPadding = max(bounds.width * 0.18, 1)
        let topPadding = max(bounds.height * 0.18, 1)
        // Extra south padding so the route sits above the bottom preview card overlay.
        let bottomPadding = max(bounds.height * 0.70, topPadding * 3)

        var paddedBounds = bounds
        paddedBounds.origin.x -= horizontalPadding
        paddedBounds.origin.y -= topPadding
        paddedBounds.size.width += horizontalPadding * 2
        paddedBounds.size.height += topPadding + bottomPadding

        isFollowingUser = false
        programmaticCameraTokens += 1
        withAnimation(.easeInOut(duration: 0.45)) {
            cameraPosition = .rect(paddedBounds)
        }
    }
}

private struct PreviewPolylineItem: Identifiable {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
    let isSelected: Bool
}
