import CoreLocation
import MapKit
import SwiftUI

/// Live, videogame-style map for the ride dashboard.
///
/// While a ride is active the camera follows the rider with a 3D pitch and a
/// speed-reactive zoom (it pulls back as you go faster). When idle it settles
/// into a gentler top-down follow to conserve battery. Draws the traveled trail,
/// the planned navigation route, and a destination pin.
struct LiveRideMapView: View {
    @Environment(AppContainer.self) private var app
    @Environment(ThemeStore.self) private var theme

    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)

    private var isRiding: Bool {
        let session = app.tripManager.sessionState
        return session.isActive && !session.isPaused
    }

    var body: some View {
        let colors = theme.palette
        let navigation = app.navigationService
        let traveled = app.tripManager.routeCoordinates
        let destination = navigation.destinationCoordinate

        Map(position: $cameraPosition) {
            UserAnnotation()

            if navigation.phase == .previewing {
                ForEach(navigation.previewRoutes) { option in
                    let isSelected = option.id == navigation.selectedRouteID
                    MapPolyline(coordinates: option.coordinates)
                        .stroke(
                            colors.neonBlue.opacity(isSelected ? 1 : 0.35),
                            style: StrokeStyle(
                                lineWidth: isSelected ? 6 : 4,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                }
            } else if navigation.routeCoordinates.count > 1 {
                MapPolyline(coordinates: navigation.routeCoordinates)
                    .stroke(
                        colors.neonBlue,
                        style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
                    )
            }

            if traveled.count > 1 {
                MapPolyline(coordinates: traveled)
                    .stroke(
                        colors.mint,
                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                    )
            }

            if let destination {
                Annotation("Destination", coordinate: destination) {
                    ZStack {
                        Circle()
                            .fill(colors.neonBlue)
                            .frame(width: 28, height: 28)
                        Image(systemName: "flag.checkered")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        // Realistic elevation is expensive on first load; keep it for active rides only.
        .mapStyle(
            .standard(
                elevation: isRiding ? .realistic : .flat,
                pointsOfInterest: .excludingAll
            )
        )
        .mapControls {
            MapCompass()
        }
        .onAppear {
            if navigation.phase == .previewing {
                fitPreviewRoute()
            } else {
                updateCamera(location: app.locationService.lastLocation)
            }
        }
        .onChange(of: app.locationService.updateTick) { _, _ in
            updateCamera(location: app.locationService.lastLocation)
        }
        .onChange(of: isRiding) { _, _ in
            updateCamera(location: app.locationService.lastLocation)
        }
        .onChange(of: navigation.previewRoutes.count) { oldCount, newCount in
            guard oldCount == 0, newCount > 0 else { return }
            fitPreviewRoute()
        }
        .onChange(of: navigation.selectedRouteID) { _, _ in
            fitPreviewRoute()
        }
    }

    private func updateCamera(location: CLLocation?) {
        guard app.navigationService.phase != .previewing else { return }
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
        let horizontalPadding = max(bounds.width * 0.12, 1)
        let verticalPadding = max(bounds.height * 0.12, 1)
        let paddedBounds = bounds.insetBy(dx: -horizontalPadding, dy: -verticalPadding)

        withAnimation(.easeInOut(duration: 0.45)) {
            cameraPosition = .rect(paddedBounds)
        }
    }
}
