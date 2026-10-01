import CoreLocation
import MapKit
import SwiftUI
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

    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var isFollowingUser = true
    /// Counts programmatic camera moves so `onMapCameraChange` does not treat them as user pans.
    @State private var programmaticCameraTokens = 0
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
        if isRiding {
            return app.tripManager.sessionState.stats.speed
        }
        guard let speed = app.locationService.lastLocation?.speed, speed >= 0 else { return 0 }
        return speed * 3.6
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
            if selectedPlace != nil { return 250 }
            if showsGlanceDial { return 230 }
            if showsMainDial { return 440 }
            return 100
        }()
        let routeColor = navigation.isNavigating ? NavigationHUDChrome.route : colors.neonBlue

        Map(position: $cameraPosition, selection: $mapSelection) {
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
                cameras: app.trafficCameraService.mapCameras,
                speedColor: colors.routeAmber,
                redLightColor: colors.neonBlue
            )
        }
        .mapStyle(
            .standard(
                elevation: isRiding ? .realistic : .flat,
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
                    .padding(.bottom, 100)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
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
                .padding(.bottom, bottomChromePadding)
                .transition(.scale.combined(with: .opacity))
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
                isFollowingUser = true
                updateCamera(location: app.locationService.lastLocation)
            }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            let wasProgrammatic = programmaticCameraTokens > 0
            if wasProgrammatic {
                programmaticCameraTokens -= 1
            }

            var following = isFollowingUser
            if !wasProgrammatic,
               app.navigationService.phase != .previewing,
               following {
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
        .onChange(of: app.locationService.updateTick) { _, _ in
            guard isFollowingUser else { return }
            updateCamera(location: app.locationService.lastLocation)
        }
        .onChange(of: isRiding) { _, riding in
            // Starting/stopping a ride also flips map elevation (.flat ↔ .realistic).
            // That MapKit camera churn can look like a user pan and clear follow —
            // especially painful when starting a ride without navigation preview,
            // which has no other path that re-asserts follow + 3D framing.
            if riding {
                isFollowingUser = true
                programmaticCameraTokens += 1
                updateCamera(location: app.locationService.lastLocation)
            } else if isFollowingUser {
                programmaticCameraTokens += 1
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

    private func recenterOnUser() {
        isFollowingUser = true
        clearSelectedPlace()
        updateCamera(location: app.locationService.lastLocation)
    }

    private func updateCamera(location: CLLocation?) {
        guard app.navigationService.phase != .previewing else { return }
        guard isFollowingUser else { return }
        guard let location else { return }

        let camera: MapCamera
        let navigation = app.navigationService
        let isNavigating = navigation.isNavigating
        if isRiding {
            let speedKmh = max(location.speed, 0) * 3.6
            let heading = location.course >= 0 ? location.course : 0
            let glanceDialVisible = isNavigating && selectedPlace == nil
            let mainDialVisible = !isNavigating && navigation.phase == .idle && selectedPlace == nil
            let center = RideFollowCameraPolicy.centerCoordinate(
                rider: location.coordinate,
                courseDegrees: location.course,
                speedKmh: speedKmh,
                isNavigating: isNavigating,
                keepsRiderAboveBottomChrome: glanceDialVisible || mainDialVisible,
                bottomChromeScale: mainDialVisible ? 0.4 : 0.62
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

struct MapPlaceCardVisibleKey: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}
