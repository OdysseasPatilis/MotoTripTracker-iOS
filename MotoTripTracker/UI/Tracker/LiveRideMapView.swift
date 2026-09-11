import CoreLocation
import MapKit
import SwiftUI
import os

/// Live, videogame-style map for the ride dashboard.
///
/// While following the rider, the camera tracks GPS (3D + speed zoom when riding,
/// gentler top-down when idle). Panning or zooming pauses follow; a Recenter
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

    var body: some View {
        let colors = theme.palette
        let navigation = app.navigationService
        let traveled = app.tripManager.routeCoordinates
        let destination = navigation.destinationCoordinate
        let previewItems = Self.previewPolylineItems(from: navigation)
        let showRecenter = !isFollowingUser && navigation.phase != .previewing
        let bottomChromePadding: CGFloat = selectedPlace == nil ? 100 : 250

        Map(position: $cameraPosition, selection: $mapSelection) {
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
            MapCompass()
        }
        .overlay(alignment: .bottom) {
            if let selectedPlace {
                placeGoCard(selectedPlace, colors: colors)
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
        .onChange(of: isRiding) { _, _ in
            guard isFollowingUser else { return }
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

    private func placeGoCard(_ place: PickedMapPlace, colors: AppPalette) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: place.categorySymbol)
                    .font(.title)
                    .foregroundStyle(colors.neonBlue)
                    .frame(width: 36, alignment: .center)

                VStack(alignment: .leading, spacing: 4) {
                    Text(place.name)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let category = place.category, !category.isEmpty {
                        Text(category)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(colors.neonBlue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(colors.neonBlue.opacity(0.14), in: Capsule())
                    }
                }

                Spacer(minLength: 0)

                Button {
                    clearSelectedPlace()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(colors.textSecondary)
                }
                .accessibilityLabel("Dismiss place")
            }

            if !place.address.isEmpty {
                labelRow(
                    systemImage: "building.2.fill",
                    text: place.address,
                    colors: colors,
                    lineLimit: 4
                )
            }

            if let phone = place.phone, !phone.isEmpty, let phoneURL = URL(string: "tel:\(phone.filter { $0.isNumber || $0 == "+" })") {
                Link(destination: phoneURL) {
                    labelRow(systemImage: "phone.fill", text: phone, colors: colors, lineLimit: 1)
                }
                .buttonStyle(.plain)
            }

            if let website = place.websiteHost, !website.isEmpty, let url = place.websiteURL {
                Link(destination: url) {
                    labelRow(systemImage: "globe", text: website, colors: colors, lineLimit: 1)
                }
                .buttonStyle(.plain)
            }

            if isResolvingPlace {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading place details…")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(colors.textSecondary)
                }
            }

            Button {
                startNavigation(to: place)
            } label: {
                Text("Go")
                    .font(.body.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(colors.bgDeep)
                    .background(colors.neonGreen, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isResolvingPlace)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func labelRow(
        systemImage: String,
        text: String,
        colors: AppPalette,
        lineLimit: Int
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(colors.textSecondary)
                .frame(width: 18, alignment: .center)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(colors.textPrimary)
                .lineLimit(lineLimit)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
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
        clearSelectedPlace()
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

private struct PickedMapPlace: Equatable, Identifiable {
    let name: String
    let category: String?
    let address: String
    let phone: String?
    let websiteHost: String?
    let websiteURL: URL?
    let latitude: Double
    let longitude: Double

    var id: String { "\(latitude),\(longitude),\(name)" }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var categorySymbol: String {
        let key = (category ?? "").lowercased()
        if key.contains("restaurant") || key.contains("cafe") || key.contains("food") {
            return "fork.knife.circle.fill"
        }
        if key.contains("hotel") || key.contains("lodging") {
            return "bed.double.circle.fill"
        }
        if key.contains("gas") || key.contains("fuel") {
            return "fuelpump.circle.fill"
        }
        if key.contains("store") || key.contains("shop") || key.contains("market") {
            return "bag.circle.fill"
        }
        if key.contains("park") || key.contains("museum") || key.contains("theater") {
            return "star.circle.fill"
        }
        return "mappin.circle.fill"
    }

    init(
        name: String,
        category: String?,
        address: String,
        phone: String?,
        websiteHost: String?,
        websiteURL: URL?,
        coordinate: CLLocationCoordinate2D
    ) {
        self.name = name
        self.category = category
        self.address = address
        self.phone = phone
        self.websiteHost = websiteHost
        self.websiteURL = websiteURL
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }
}

private struct PreviewPolylineItem: Identifiable {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
    let isSelected: Bool
}
