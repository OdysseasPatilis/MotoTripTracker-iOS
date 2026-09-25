import Combine
import CoreLocation
import MapKit
import SwiftData
import SwiftUI
import os

enum MapLayer: String, CaseIterable, Identifiable {
    case speed = "Speed"
    case elevation = "Elevation"
    var id: String { rawValue }
}

struct FullRouteView: View {
    @Environment(AppContainer.self) private var app
    @Environment(ThemeStore.self) private var theme

    let tripID: UUID
    @Query private var trips: [Trip]
    @Query private var storedPoints: [RoutePoint]
    @State private var points: [RoutePoint] = []
    @State private var displayCoordinates: [CLLocationCoordinate2D] = []
    @State private var waypoints: [RoutePoint] = []
    @State private var selectedLayer: MapLayer = .speed
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var tripDistanceKm: Double = 0
    @State private var replayElapsed: TimeInterval = 0
    @State private var isReplaying = false
    @State private var playbackRate: Double = 1
    @State private var replayAnchor = Date()
    @State private var replayStartElapsed: TimeInterval = 0
    @State private var selectedWaypointID: UUID?
    @State private var usingPolylineFallback = false

    init(tripID: UUID) {
        self.tripID = tripID
        let id = tripID
        _trips = Query(filter: #Predicate<Trip> { $0.id == id })
        _storedPoints = Query(
            filter: #Predicate<RoutePoint> { $0.trip?.id == id },
            sort: [SortDescriptor(\.timestamp)]
        )
    }

    private var trip: Trip? { trips.first }

    private var replayEngine: RouteReplayEngine { RouteReplayEngine(points: points) }
    private var replayFrame: RouteReplayFrame? { replayEngine.frame(at: replayElapsed) }

    var body: some View {
        let colors = theme.palette

        ScrollViewReader { proxy in
            List {
                if replayEngine.isValid {
                    Section("Replay") {
                        replayControls(colors: colors)
                            .listRowBackground(colors.bgCard)
                    }
                }

                Section {
                    Picker("Layer", selection: $selectedLayer) {
                        ForEach(MapLayer.allCases) { layer in
                            Text(layer.rawValue).tag(layer)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }

                Section {
                    routeMap(colors: colors)
                        .frame(height: 300)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .id(selectedLayer)
                }
                .id("route-map")

                Section {
                    FullRouteProfileChart(
                        points: points,
                        selectedLayer: selectedLayer,
                        tripDistanceKm: tripDistanceKm,
                        colors: colors
                    )
                    .listRowBackground(Color.clear)
                    FullRouteLegendCaption(selectedLayer: selectedLayer, colors: colors)
                        .listRowBackground(Color.clear)
                }

                if !waypoints.isEmpty {
                    Section("Waypoints") {
                        ForEach(waypoints, id: \.id) { waypoint in
                            waypointRow(waypoint, colors: colors)
                                .id(waypoint.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectWaypoint(waypoint)
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        proxy.scrollTo("route-map", anchor: .center)
                                    }
                                }
                                .listRowBackground(
                                    selectedWaypointID == waypoint.id
                                        ? colors.neonBlue.opacity(0.14)
                                        : colors.bgCard
                                )
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(colors.bgDeep.ignoresSafeArea())
            .onChange(of: selectedWaypointID) { _, newID in
                guard let newID else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
        .navigationTitle("Route")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            applyRouteDisplay()
            Task {
                await app.repository.ensureWaypointsAnalyzed(tripID: tripID)
                applyRouteDisplay()
            }
        }
        .onDisappear {
            isReplaying = false
        }
        .onChange(of: replayElapsed) { _, elapsed in
            guard isReplaying, let frame = replayEngine.frame(at: elapsed) else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                cameraPosition = .region(
                    MKCoordinateRegion(
                        center: frame.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
                    )
                )
            }
        }
        .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { now in
            guard isReplaying, replayEngine.duration > 0 else { return }
            let delta = now.timeIntervalSince(replayAnchor) * playbackRate
            replayElapsed = min(replayEngine.duration, replayStartElapsed + delta)
            if replayElapsed >= replayEngine.duration {
                isReplaying = false
            }
        }
    }

    private func waypointRow(_ waypoint: RoutePoint, colors: AppPalette) -> some View {
        let isSelected = selectedWaypointID == waypoint.id
        return HStack(spacing: 12) {
            Image(systemName: FullRouteMapStyling.iconName(for: waypoint.waypointType))
                .foregroundStyle(FullRouteMapStyling.markerColor(for: waypoint.waypointType, colors: colors))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(waypoint.waypointTitle)
                    .font(.body.weight(.medium))
                    .foregroundStyle(colors.textPrimary)
                Text(waypoint.waypointSubtitle)
                    .font(.caption)
                    .foregroundStyle(colors.textSecondary)
            }
            Spacer(minLength: 0)
            if isSelected {
                Image(systemName: "mappin.and.ellipse")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(colors.neonBlue)
            }
        }
        .padding(.vertical, 2)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func selectWaypoint(_ waypoint: RoutePoint) {
        isReplaying = false
        selectedWaypointID = waypoint.id
        let coordinate = CLLocationCoordinate2D(latitude: waypoint.latitude, longitude: waypoint.longitude)
        withAnimation(.easeInOut(duration: 0.35)) {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
                )
            )
        }
    }

    private func applyRouteDisplay() {
        let display = RideRouteDisplay.resolve(trip: trip, storedPoints: storedPoints)
        if display.usingPolylineFallback {
            AppLogger.persistence.warning(
                "FullRoute fallback to encoded polyline id=\(AppLogger.uuidShort(tripID), privacy: .public) verts=\(display.points.count)"
            )
        }
        points = display.points
        displayCoordinates = display.coordinates
        waypoints = display.waypoints
        usingPolylineFallback = display.usingPolylineFallback
        tripDistanceKm = (trip?.distanceMeters ?? 0) / 1000
        replayElapsed = 0
        isReplaying = false
        if let region = FullRouteMapStyling.region(fitting: displayCoordinates) {
            cameraPosition = .region(region)
        }
    }

    @ViewBuilder
    private func replayControls(colors: AppPalette) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    if isReplaying {
                        isReplaying = false
                    } else {
                        replayStartElapsed = replayElapsed
                        replayAnchor = Date()
                        if replayElapsed >= replayEngine.duration {
                            replayElapsed = 0
                            replayStartElapsed = 0
                        }
                        isReplaying = true
                    }
                } label: {
                    Image(systemName: isReplaying ? "pause.fill" : "play.fill")
                        .font(.headline)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.borderedProminent)
                .tint(colors.neonGreen)

                Button {
                    replayElapsed = 0
                    isReplaying = false
                } label: {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(.bordered)
                .tint(colors.neonBlue)

                Picker("Speed", selection: $playbackRate) {
                    Text("1×").tag(1.0)
                    Text("2×").tag(2.0)
                    Text("4×").tag(4.0)
                }
                .pickerStyle(.segmented)

                Spacer(minLength: 0)

                if let frame = replayFrame {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Int(frame.speedKmh.rounded())) km/h")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(colors.neonGreen)
                        Text(RideFormatters.secondsToTime(Int64(frame.elapsed)))
                            .font(.caption2)
                            .foregroundStyle(colors.textSecondary)
                    }
                }
            }

            if replayEngine.duration > 0 {
                Slider(
                    value: Binding(
                        get: { replayElapsed },
                        set: { newValue in
                            replayElapsed = newValue
                            replayAnchor = Date()
                            isReplaying = false
                        }
                    ),
                    in: 0...replayEngine.duration
                )
                .tint(colors.neonGreen)
            }
        }
        .padding(.vertical, 4)
    }

    private func routeMap(colors: AppPalette) -> some View {
        let traveled = replayFrame.flatMap { replayEngine.isValid ? replayEngine.trailCoordinates(upTo: $0) : nil } ?? []
        let remaining = replayFrame.flatMap { remainingReplayCoordinates(from: $0) } ?? []

        return Map(position: $cameraPosition) {
            // Only split traveled/remaining while actively replaying. Idle used to
            // stay in this branch at t=0 (empty green stub + easy-to-miss gray line).
            if isReplaying, let frame = replayFrame, replayEngine.isValid {
                if traveled.count >= 2 {
                    MapPolyline(coordinates: traveled)
                        .stroke(colors.neonGreen, lineWidth: 6)
                }
                if remaining.count >= 2 {
                    MapPolyline(coordinates: remaining)
                        .stroke(colors.textSecondary.opacity(0.35), lineWidth: 4)
                }
                Annotation("Rider", coordinate: frame.coordinate) {
                    ZStack {
                        Circle()
                            .fill(colors.neonGreen.opacity(0.25))
                            .frame(width: 28, height: 28)
                        Circle()
                            .fill(colors.neonGreen)
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(colors.bgDeep, lineWidth: 2))
                    }
                }
            } else if displayCoordinates.count >= 2 {
                ForEach(Array(FullRouteMapStyling.mergedSegments(
                    points: points,
                    selectedLayer: selectedLayer,
                    usingPolylineFallback: usingPolylineFallback,
                    colors: colors
                ).enumerated()), id: \.offset) { _, segment in
                    MapPolyline(coordinates: segment.coordinates)
                        .stroke(segment.color, lineWidth: 5)
                }
            }
            ForEach(waypoints, id: \.id) { waypoint in
                let isSelected = selectedWaypointID == waypoint.id
                Annotation(
                    waypoint.waypointTitle,
                    coordinate: CLLocationCoordinate2D(
                        latitude: waypoint.latitude,
                        longitude: waypoint.longitude
                    )
                ) {
                    Button {
                        selectWaypoint(waypoint)
                    } label: {
                        ZStack {
                            if isSelected {
                                Circle()
                                    .fill(FullRouteMapStyling.markerColor(for: waypoint.waypointType, colors: colors).opacity(0.28))
                                    .frame(width: 44, height: 44)
                            }
                            Image(systemName: FullRouteMapStyling.iconName(for: waypoint.waypointType))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(isSelected ? 9 : 6)
                                .background(
                                    FullRouteMapStyling.markerColor(for: waypoint.waypointType, colors: colors),
                                    in: Circle()
                                )
                                .overlay(
                                    Circle()
                                        .stroke(isSelected ? colors.neonBlue : .clear, lineWidth: 2)
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(waypoint.waypointTitle)
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .topLeading) {
            if usingPolylineFallback {
                Text("Route from saved path · limited replay detail")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(10)
            }
        }
    }

    private func remainingReplayCoordinates(from frame: RouteReplayFrame) -> [CLLocationCoordinate2D] {
        let remainingStart = min(frame.segmentIndex + 1, points.count - 1)
        guard remainingStart < points.count - 1 else { return [] }
        var coords = points[remainingStart...].map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        coords.insert(frame.coordinate, at: 0)
        return coords
    }
}

#Preview {
    let app = AppContainer(inMemory: true)
    NavigationStack {
        FullRouteView(tripID: UUID())
    }
    .environment(app)
    .environment(app.theme)
    .modelContainer(app.modelContainer)
}
