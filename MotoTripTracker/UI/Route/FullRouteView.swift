import Combine
import CoreLocation
import MapKit
import SwiftUI

enum MapLayer: String, CaseIterable, Identifiable {
    case speed = "Speed"
    case elevation = "Elevation"
    var id: String { rawValue }
}

struct FullRouteView: View {
    @Environment(AppContainer.self) private var app
    @Environment(ThemeStore.self) private var theme

    let tripID: UUID
    @State private var points: [RoutePoint] = []
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
                    profileChart(colors: colors)
                        .listRowBackground(Color.clear)
                    legendCaption(colors: colors)
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
            loadRouteData()
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
            Image(systemName: iconName(for: waypoint.waypointType))
                .foregroundStyle(markerColor(for: waypoint.waypointType, colors: colors))
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

    private func loadRouteData() {
        points = app.repository.routePoints(for: tripID)
        waypoints = app.repository.waypoints(for: tripID)
        tripDistanceKm = (app.repository.fetchTrip(id: tripID)?.distanceMeters ?? 0) / 1000
        replayElapsed = 0
        isReplaying = false
        let coords = points.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        if let region = Self.region(fitting: coords) {
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
            if let frame = replayFrame, replayEngine.isValid {
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
            } else {
                ForEach(Array(segments(colors: colors).enumerated()), id: \.offset) { _, segment in
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
                                    .fill(markerColor(for: waypoint.waypointType, colors: colors).opacity(0.28))
                                    .frame(width: 44, height: 44)
                            }
                            Image(systemName: iconName(for: waypoint.waypointType))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(isSelected ? 9 : 6)
                                .background(
                                    markerColor(for: waypoint.waypointType, colors: colors),
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

    private func profileChart(colors: AppPalette) -> some View {
        let values: [Double] = points.map { point in
            selectedLayer == .elevation ? point.altitude : point.speedMps * 3.6
        }
        let lineColor = selectedLayer == .elevation ? colors.neonBlue : colors.routeTeal
        let fillColor = lineColor.opacity(0.12)
        let peak = values.max() ?? 0
        let peakLabel = selectedLayer == .elevation
            ? "+\(Int(peak)) m peak"
            : "\(Int(peak)) km/h peak"
        let peakColor = selectedLayer == .elevation ? colors.neonBlue : colors.routeCoral

        return VStack(alignment: .leading, spacing: 8) {
            Text(selectedLayer == .elevation ? "Elevation profile" : "Speed profile")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(colors.textPrimary)

            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(colors.bgCard))

                guard values.count > 1 else { return }

                let pad: CGFloat = 10
                let minV = values.min() ?? 0
                let maxV = values.max() ?? 1
                let range = max(maxV - minV, 1)
                let usableWidth = size.width - pad * 2
                let usableHeight = size.height - pad * 2

                func point(at index: Int) -> CGPoint {
                    let x = pad + usableWidth * CGFloat(index) / CGFloat(values.count - 1)
                    let y = pad + usableHeight * (1 - CGFloat((values[index] - minV) / range))
                    return CGPoint(x: x, y: y)
                }

                var path = Path()
                for index in values.indices {
                    let p = point(at: index)
                    if index == 0 {
                        path.move(to: p)
                    } else {
                        path.addLine(to: p)
                    }
                }

                var fill = path
                fill.addLine(to: CGPoint(x: pad + usableWidth, y: size.height - pad))
                fill.addLine(to: CGPoint(x: pad, y: size.height - pad))
                fill.closeSubpath()
                context.fill(fill, with: .color(fillColor))
                context.stroke(path, with: .color(lineColor), lineWidth: 2)
            }
            .frame(height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .id(selectedLayer)

            HStack {
                Text("0 km")
                    .font(.caption2)
                    .foregroundStyle(colors.textSecondary)
                Spacer()
                Text(peakLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(peakColor)
                Spacer()
                Text(String(format: "%.1f km", tripDistanceKm))
                    .font(.caption2)
                    .foregroundStyle(colors.textSecondary)
            }
        }
    }

    private func legendCaption(colors: AppPalette) -> some View {
        let text: String = selectedLayer == .speed
            ? "Slow 0–40 · Cruise 40–130 · Fast 130+ km/h"
            : "Low · Mid · High elevation thirds"
        return Text(text)
            .font(.caption)
            .foregroundStyle(colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct RouteSegment {
        let coordinates: [CLLocationCoordinate2D]
        let color: Color
    }

    private func segments(colors: AppPalette) -> [RouteSegment] {
        guard points.count > 1 else { return [] }
        let altitudes = points.map(\.altitude)
        let minE = altitudes.min() ?? 0
        let maxE = altitudes.max() ?? 0

        var result: [RouteSegment] = []
        for i in 0..<(points.count - 1) {
            let a = points[i]
            let b = points[i + 1]
            let color: Color
            if selectedLayer == .speed {
                let kmh = a.speedMps * 3.6
                if kmh < 40 {
                    color = colors.routeAmber
                } else if kmh < 130 {
                    color = colors.routeTeal
                } else {
                    color = colors.routeCoral
                }
            } else {
                let elev = a.altitude
                let t = maxE > minE ? (elev - minE) / (maxE - minE) : 0.5
                color = t < 0.33 ? colors.routeTeal : (t < 0.66 ? colors.neonBlue : colors.routeCoral)
            }
            result.append(
                RouteSegment(
                    coordinates: [
                        CLLocationCoordinate2D(latitude: a.latitude, longitude: a.longitude),
                        CLLocationCoordinate2D(latitude: b.latitude, longitude: b.longitude)
                    ],
                    color: color
                )
            )
        }
        return result
    }

    private func iconName(for type: String?) -> String {
        switch type {
        case "START": return "flag.fill"
        case "END": return "flag.checkered"
        case "TOP_SPEED": return "gauge.with.dots.needle.67percent"
        case "SUMMIT": return "mountain.2.fill"
        case "STOP_SIGN": return "stop.circle.fill"
        case "TRAFFIC_LIGHT": return "light.beacon.max.fill"
        case "BRIEF_STOP", "REST_STOP": return "cup.and.saucer.fill"
        default: return "mappin.circle.fill"
        }
    }

    private func markerColor(for type: String?, colors: AppPalette) -> Color {
        switch type {
        case "START": return colors.neonGreen
        case "END": return colors.neonRed
        case "TOP_SPEED": return colors.routeAmber
        case "SUMMIT": return Color(hex: 0xD988FF)
        case "REST_STOP": return colors.neonBlue
        default: return colors.layerActive
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
                latitudeDelta: max((maxLat - minLat) * 1.4, 0.01),
                longitudeDelta: max((maxLng - minLng) * 1.4, 0.01)
            )
        )
    }
}
