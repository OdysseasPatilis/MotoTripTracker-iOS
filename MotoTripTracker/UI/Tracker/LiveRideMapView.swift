import CoreLocation
import MapKit
import SwiftUI
import UIKit
import os

/// Live, videogame-style map for the ride dashboard.
///
/// While following the rider, the camera tracks GPS (3D + speed zoom, look-ahead
/// center, and turn-approach zoom when riding; gentler top-down when idle).
/// Panning or zooming pauses follow; a Recenter
/// button restores it. Tapping a map point of interest shows a Go card that
/// starts the existing route-preview flow. Draws the traveled trail, planned
/// navigation route, traffic cameras, and a destination pin.
struct LiveRideMapView: View {
    @Environment(AppContainer.self) private var app
    @Environment(ThemeStore.self) private var theme
    @Environment(\.dashboardIsVisible) private var dashboardIsVisible

    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var isFollowingUser = true
    /// One callback consumes every camera move the app queued, so a later pan still counts as the user's.
    @State private var cameraGate = MapProgrammaticCameraGate()
    /// Set on touch-down, before the next GPS fix can snap the camera back.
    @State private var followPause = MapFollowPause()
    /// Ride start resizes the map. Ignore those camera callbacks so follow stays on the dot.
    @State private var suppressFollowReleaseUntil = Date.distantPast
    @State private var mapSelection: MapSelection<MKMapItem>?
    @State private var selectedPlace: PickedMapPlace?
    @State private var isResolvingPlace = false
    @State private var placeResolveGeneration = 0

    private var isRiding: Bool {
        let session = app.tripManager.sessionState
        return session.isActive && !session.isPaused
    }

    /// Smoothed trip speed once a ride is recording. Before Start, TripManager
    /// publishes 0, so the dial uses the live GPS speed instead.
    private var glanceSpeedKmh: Double {
        guard dashboardIsVisible else { return 0 }
        if isRiding {
            return app.tripManager.sessionState.stats.speed
        }
        guard let location = app.locationService.lastLocation else { return 0 }
        return SpeedFilter().processedSpeed(from: location) * 3.6
    }

    var body: some View {
        let colors = theme.palette
        let navigation = app.navigationService
        let traveled = app.tripManager.routeCoordinates
        let destination = navigation.destinationCoordinate
        let previewItems = Self.previewPolylineItems(from: navigation)
        let showRecenter = !isFollowingUser && navigation.phase != .previewing
        let showsGlanceDial = navigation.isNavigating && selectedPlace == nil
        let showsMainDial = navigation.phase == .idle && selectedPlace == nil
        let bottomChromePadding: CGFloat = {
            if showsGlanceDial { return 230 }
            if showsMainDial { return 530 }
            return 100
        }()
        let routeColor = navigation.isNavigating ? NavigationHUDChrome.route : colors.neonBlue

        let rider = dashboardIsVisible ? app.locationService.lastLocation : nil
        let riderCourse = rider?.course ?? -1
        let riderSpeed = rider?.speed ?? -1
        let pointing = RiderPointing.degrees(
            course: riderCourse,
            speedMps: riderSpeed,
            compassDegrees: dashboardIsVisible ? app.locationService.lastHeadingDegrees : nil
        )
        let mapHeading: CLLocationDirection = (isRiding && riderCourse >= 0) ? riderCourse : 0

        Map(position: $cameraPosition, selection: $mapSelection) {
            if let coordinate = rider?.coordinate, let pointing {
                Annotation("", coordinate: coordinate, anchor: .center) {
                    HeadingBeam()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0, green: 0.48, blue: 1).opacity(0.05),
                                    Color(red: 0, green: 0.48, blue: 1).opacity(0.5)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 40, height: 36)
                        .offset(y: -22)
                        .rotationEffect(.degrees(pointing - mapHeading))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            UserAnnotation()
            routeOverlays(
                previewItems: previewItems,
                activeRoute: navigation.phase == .previewing ? [] : navigation.routeCoordinates,
                traveled: traveled,
                routeColor: routeColor,
                trailColor: colors.mint,
                glowRoute: navigation.isNavigating
            )
            if let destination {
                destinationAnnotation(coordinate: destination, color: colors.neonBlue)
            }
            cameraAnnotations(
                cameras: dashboardIsVisible ? app.trafficCameraService.mapCameras : [],
                speedColor: colors.routeAmber,
                redLightColor: colors.neonBlue
            )
        }
        .mapStyle(
            .standard(
                elevation: navigation.isNavigating ? .realistic : .flat,
                pointsOfInterest: .all,
                showsTraffic: true
            )
        )
        .mapFeatureSelectionDisabled { feature in
            feature.kind != .pointOfInterest
        }
        .mapControls {
            if !navigation.isNavigating {
                MapCompass()
            }
        }
        .overlay {
            MapInteractionSpy(isEnabled: isFollowingUser && navigation.phase != .previewing) {
                pauseFollowForTouch()
            }
        }
        .overlay(alignment: .bottom) {
            if showsGlanceDial {
                NavigationInstrumentCluster(
                    speedKmh: glanceSpeedKmh,
                    speedLimitKmh: app.speedLimitService.effectiveLimitKmh,
                    trafficHint: navigation.trafficHintText,
                    overLimitColor: colors.stopRed,
                    hintColor: colors.routeAmber
                )
                .padding(.bottom, 8)
                .allowsHitTesting(false)
                .transition(.opacity)
            } else if let selectedPlace {
                LiveRideMapPlaceCard(
                    place: selectedPlace,
                    colors: colors,
                    isResolving: isResolvingPlace,
                    onDismiss: clearSelectedPlace,
                    onGo: { startNavigation(to: selectedPlace) }
                )
                    .padding(.horizontal, 10)
                    .padding(.bottom, 120)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showRecenter, selectedPlace == nil {
                recenterButton(tint: colors.neonBlue)
                    .padding(.trailing, 12)
                    .padding(.bottom, bottomChromePadding)
            }
        }
        .overlay(alignment: .topLeading) {
            // The place card's close button owns the top-right of the card.
            // Keep recenter under the GPS chip, on the opposite side.
            if showRecenter, selectedPlace != nil {
                recenterButton(tint: colors.neonBlue)
                    .padding(.leading, 12)
                    .padding(.top, navigation.isNavigating ? 168 : 72)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showRecenter)
        .animation(.easeInOut(duration: 0.2), value: selectedPlace?.id)
        .preference(key: MapPlaceCardVisibleKey.self, value: selectedPlace != nil)
        .onChange(of: mapSelection) { _, newSelection in
            handleMapSelectionChange(newSelection)
        }
        .onChange(of: navigation.phase) { oldPhase, newPhase in
            if newPhase == .previewing {
                isFollowingUser = false
                clearSelectedPlace()
            } else if oldPhase == .previewing {
                followPause.isPaused = false
                isFollowingUser = true
                updateCamera(location: app.locationService.lastLocation)
            }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            let wasProgrammatic = cameraGate.consumeIfProgrammatic()

            var following = isFollowingUser && !followPause.isPaused
            let suppressRelease = Date() < suppressFollowReleaseUntil
            if !wasProgrammatic,
               !suppressRelease,
               app.navigationService.phase != .previewing,
               following {
                followPause.isPaused = true
                following = false
                isFollowingUser = false
            }

            let region = context.region
            let exploring = !following && app.navigationService.phase != .previewing
            app.trafficCameraService.updateVisibleMapRegion(
                centerLatitude: region.center.latitude,
                centerLongitude: region.center.longitude,
                latitudeDelta: region.span.latitudeDelta,
                longitudeDelta: region.span.longitudeDelta,
                fetchRemote: exploring
            )
        }
        .onAppear {
            if navigation.phase == .previewing {
                fitPreviewRoute()
            } else if isFollowingUser {
                updateCamera(location: app.locationService.lastLocation)
            }
        }
        .onChange(of: dashboardIsVisible ? app.locationService.updateTick : 0) { _, _ in
            guard dashboardIsVisible, isFollowingUser, !followPause.isPaused else { return }
            updateCamera(location: app.locationService.lastLocation)
        }
        .onChange(of: dashboardIsVisible) { _, visible in
            guard visible, isFollowingUser, !followPause.isPaused else { return }
            updateCamera(location: app.locationService.lastLocation)
        }
        .onChange(of: isRiding) { _, riding in
            // Starting a ride changes the bottom controls and the map size.
            // That camera nudge is not a pan — keep the view locked on the dot.
            suppressFollowReleaseUntil = Date().addingTimeInterval(1.2)
            if riding {
                followPause.isPaused = false
                isFollowingUser = true
                updateCamera(location: app.locationService.lastLocation)
            } else if isFollowingUser, !followPause.isPaused {
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

    private func handleMapSelectionChange(_ selection: MapSelection<MKMapItem>?) {
        guard let selection else {
            selectedPlace = nil
            isResolvingPlace = false
            return
        }

        if let item = selection.value {
            applyMapItem(item)
            return
        }

        guard let feature = selection.feature else {
            selectedPlace = nil
            return
        }

        placeResolveGeneration &+= 1
        let generation = placeResolveGeneration
        isResolvingPlace = true
        // Show a lightweight placeholder from the feature title while details load.
        if let title = feature.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            selectedPlace = PickedMapPlace(
                name: title,
                category: nil,
                address: "",
                phone: nil,
                websiteHost: nil,
                websiteURL: nil,
                coordinate: feature.coordinate
            )
        }
        Task {
            defer {
                if generation == placeResolveGeneration {
                    isResolvingPlace = false
                }
            }
            do {
                let request = MKMapItemRequest(feature: feature)
                let item = try await request.mapItem
                guard generation == placeResolveGeneration else { return }
                applyMapItem(item)
            } catch {
                guard generation == placeResolveGeneration else { return }
                if selectedPlace == nil {
                    selectedPlace = nil
                }
                AppLogger.app.warning(
                    "Map place resolve failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func applyMapItem(_ item: MKMapItem) {
        let coordinate = MapKitPlace.coordinate(of: item)
        guard CLLocationCoordinate2DIsValid(coordinate) else {
            selectedPlace = nil
            return
        }
        let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedPlace = PickedMapPlace(
            name: (name?.isEmpty == false) ? name! : "Selected place",
            category: MapKitPlace.categoryLabel(of: item),
            address: MapKitPlace.fullAddress(of: item) ?? "",
            phone: MapKitPlace.phoneNumber(of: item),
            websiteHost: MapKitPlace.websiteHost(of: item),
            websiteURL: MapKitPlace.websiteURL(of: item),
            coordinate: coordinate
        )
        followPause.isPaused = true
        isFollowingUser = false
    }

    private func startNavigation(to place: PickedMapPlace) {
        clearSelectedPlace()
        app.navigationService.setDestination(
            coordinate: place.coordinate,
            name: place.name,
            subtitle: place.address
        )
    }

    private func clearSelectedPlace() {
        placeResolveGeneration &+= 1
        selectedPlace = nil
        mapSelection = nil
        isResolvingPlace = false
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
        trailColor: Color,
        glowRoute: Bool
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
            if glowRoute {
                MapPolyline(coordinates: activeRoute)
                    .stroke(
                        routeColor.opacity(0.38),
                        style: StrokeStyle(lineWidth: 14, lineCap: .round, lineJoin: .round)
                    )
            }
            MapPolyline(coordinates: activeRoute)
                .stroke(
                    routeColor,
                    style: StrokeStyle(lineWidth: glowRoute ? 5 : 6, lineCap: .round, lineJoin: .round)
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

    private func recenterButton(tint: Color) -> some View {
        Button {
            recenterOnUser()
        } label: {
            Image(systemName: "location.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Recenter map on my location")
        .transition(.scale.combined(with: .opacity))
    }

    private func pauseFollowForTouch() {
        guard app.navigationService.phase != .previewing else { return }
        guard isFollowingUser || !followPause.isPaused else { return }
        followPause.isPaused = true
        // hitTest can run inside a view update. The flag above already blocks the next camera snap.
        DispatchQueue.main.async {
            isFollowingUser = false
        }
    }

    private func recenterOnUser() {
        followPause.isPaused = false
        isFollowingUser = true
        clearSelectedPlace()
        updateCamera(location: app.locationService.lastLocation)
    }

    private func updateCamera(location: CLLocation?) {
        guard app.navigationService.phase != .previewing else { return }
        guard isFollowingUser, !followPause.isPaused else { return }
        guard selectedPlace == nil else {
            followPause.isPaused = true
            isFollowingUser = false
            return
        }
        guard let location else { return }

        let camera: MapCamera
        let navigation = app.navigationService
        let isNavigating = navigation.isNavigating
        if isRiding && !isNavigating {
            // Stay on the location dot. Look-ahead would slide it off the point that is moving.
            let mainDialVisible = navigation.phase == .idle && selectedPlace == nil
            let center = mainDialVisible
                ? RideFollowCameraPolicy.idleCenterAboveBottomDial(
                    rider: location.coordinate,
                    cameraDistanceMeters: 1400
                )
                : location.coordinate
            camera = MapCamera(
                centerCoordinate: center,
                distance: 1400,
                heading: 0,
                pitch: 0
            )
        } else if isRiding {
            let speedKmh = max(location.speed, 0) * 3.6
            let heading = location.course >= 0 ? location.course : 0
            let glanceDialVisible = selectedPlace == nil
            let center = RideFollowCameraPolicy.centerCoordinate(
                rider: location.coordinate,
                courseDegrees: location.course,
                speedKmh: speedKmh,
                isNavigating: isNavigating,
                keepsRiderAboveBottomChrome: glanceDialVisible,
                bottomChromeScale: 0.62
            )
            let distance = RideFollowCameraPolicy.cameraDistanceMeters(
                speedKmh: speedKmh,
                distanceToNextManeuver: isNavigating ? navigation.distanceToNextManeuver : nil,
                isNavigating: isNavigating,
                isRecalculating: navigation.isRecalculating
            )
            camera = MapCamera(
                centerCoordinate: center,
                distance: distance,
                heading: heading,
                pitch: 55
            )
        } else {
            let mainDialVisible = !isNavigating && navigation.phase == .idle && selectedPlace == nil
            let center = mainDialVisible
                ? RideFollowCameraPolicy.idleCenterAboveBottomDial(
                    rider: location.coordinate,
                    cameraDistanceMeters: 1400
                )
                : location.coordinate
            camera = MapCamera(
                centerCoordinate: center,
                distance: 1400,
                heading: 0,
                pitch: 0
            )
        }

        cameraGate.markProgrammatic()
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

        followPause.isPaused = true
        isFollowingUser = false
        cameraGate.markProgrammatic()
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

struct MapPlaceCardVisibleKey: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// Collapses a burst of app-driven camera moves into one ignored callback.
/// The next callback after that is the user's pan or zoom.
struct MapProgrammaticCameraGate: Equatable {
    private var generation = 0
    private var consumedGeneration = 0

    mutating func markProgrammatic() {
        generation &+= 1
    }

    mutating func consumeIfProgrammatic() -> Bool {
        guard generation != consumedGeneration else { return false }
        consumedGeneration = generation
        return true
    }
}

/// Touch-down flag. A class so the map can see it before SwiftUI renders the next frame.
private final class MapFollowPause {
    var isPaused = false
}

/// Direction the location cone should point. Course wins once you're actually moving;
/// otherwise the compass shows where the phone is aimed.
enum RiderPointing {
    static func degrees(
        course: CLLocationDirection,
        speedMps: CLLocationSpeed,
        compassDegrees: CLLocationDirection?
    ) -> CLLocationDirection? {
        if speedMps >= SpeedFilter.stationaryFloorMps, course >= 0 {
            return course
        }
        guard let compassDegrees, compassDegrees >= 0 else { return nil }
        return compassDegrees
    }
}

/// Wide end faces forward, tip sits on the rider. Same shape as the Maps heading cone.
private struct HeadingBeam: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Sees a finger on the map without taking the touch away from MapKit.
private struct MapInteractionSpy: UIViewRepresentable {
    var isEnabled: Bool
    var onUserInteraction: () -> Void

    func makeUIView(context: Context) -> SpyView {
        let view = SpyView()
        view.isEnabled = isEnabled
        view.onUserInteraction = onUserInteraction
        return view
    }

    func updateUIView(_ uiView: SpyView, context: Context) {
        uiView.isEnabled = isEnabled
        uiView.onUserInteraction = onUserInteraction
    }

    final class SpyView: UIView {
        var isEnabled = false
        var onUserInteraction: () -> Void = {}

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isOpaque = false
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            if isEnabled, event != nil {
                onUserInteraction()
            }
            return nil
        }
    }
}
