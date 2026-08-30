import CoreLocation
import Foundation
import MapKit
import UIKit
import os

/// A single turn-by-turn maneuver extracted from `MKRoute.Step`.
struct NavStep: Sendable, Identifiable, Hashable {
    let id: UUID
    let instruction: String
    let distance: CLLocationDistance
    let endLatitude: Double
    let endLongitude: Double

    var endCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: endLatitude, longitude: endLongitude)
    }

    init(instruction: String, distance: CLLocationDistance, endCoordinate: CLLocationCoordinate2D) {
        self.id = UUID()
        self.instruction = instruction
        self.distance = distance
        self.endLatitude = endCoordinate.latitude
        self.endLongitude = endCoordinate.longitude
    }
}

/// Destination search, driving routes, and in-app turn-by-turn guidance.
@Observable
@MainActor
final class NavigationService: NSObject, MKLocalSearchCompleterDelegate {
    var searchQuery: String = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            if searchQuery.isEmpty {
                searchResults = []
            } else {
                completer.queryFragment = searchQuery
            }
        }
    }

    private(set) var searchResults: [MKLocalSearchCompletion] = []

    private(set) var destinationCoordinate: CLLocationCoordinate2D?
    private(set) var destinationName: String?
    private(set) var routeCoordinates: [CLLocationCoordinate2D] = []
    private(set) var distanceRemaining: CLLocationDistance = 0
    private(set) var eta: Date?
    private(set) var isRouting = false
    private(set) var isOffRoute = false
    private(set) var isRecalculating = false

    private(set) var steps: [NavStep] = []
    private(set) var currentStepIndex: Int = 0
    /// Distance from the rider to the end of the current maneuver.
    private(set) var distanceToNextManeuver: CLLocationDistance = 0

    private let completer = MKLocalSearchCompleter()
    private var origin: CLLocationCoordinate2D?
    private var totalRouteDistance: CLLocationDistance = 0
    private var totalTravelTime: TimeInterval = 0
    private var lastRecalculateAt: Date = .distantPast
    private var nearestRouteDistance: CLLocationDistance = 0

    /// Called when a driving route is applied (initial or recalculated).
    var onRouteApplied: (([CLLocationCoordinate2D], TimeInterval) -> Void)?
    var onRouteCleared: (() -> Void)?

    /// How far from the planned polyline before we treat the rider as off-route.
    private static let offRouteThresholdMeters: CLLocationDistance = 80
    /// Advance to the next step when within this distance of its end.
    private static let stepAdvanceMeters: CLLocationDistance = 35
    private static let recalculateCooldown: TimeInterval = 12

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    /// Starts MapKit's local-search daemon so the first destination sheet isn't cold.
    func warmUpSearchCompleter() {
        guard searchQuery.isEmpty else { return }
        completer.queryFragment = " "
        completer.queryFragment = ""
        searchResults = []
    }

    var hasDestination: Bool { destinationCoordinate != nil }
    var hasRoute: Bool { routeCoordinates.count > 1 }

    /// 0 at departure, 1 when the planned route is complete.
    var routeProgressFraction: Double {
        guard totalRouteDistance > 0 else { return 0 }
        let traveled = max(0, totalRouteDistance - distanceRemaining)
        return min(1, traveled / totalRouteDistance)
    }

    var currentStep: NavStep? {
        guard steps.indices.contains(currentStepIndex) else { return nil }
        return steps[currentStepIndex]
    }

    var summaryText: String {
        let distanceString = Self.formatDistance(distanceRemaining)
        guard let eta else { return distanceString }
        return "\(distanceString) · ETA \(eta.formatted(date: .omitted, time: .shortened))"
    }

    /// Compact line for the Live Activity / HUD secondary line.
    var guidanceSummary: String {
        if isRecalculating { return "Recalculating…" }
        if isOffRoute { return "Off route — recalculating" }
        if let step = currentStep {
            return "\(Self.formatDistance(distanceToNextManeuver)) · \(step.instruction)"
        }
        return summaryText
    }

    /// Called on every GPS fix. Updates search region, remaining distance/ETA,
    /// turn-by-turn step progress, and triggers off-route recalculation.
    func updateOrigin(_ coordinate: CLLocationCoordinate2D) {
        origin = coordinate
        completer.region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 60_000,
            longitudinalMeters: 60_000
        )
        guard hasRoute else { return }
        recomputeRemaining(from: coordinate)
        advanceStepIfNeeded(from: coordinate)
        checkOffRouteAndRecalculate(from: coordinate)
    }

    func selectCompletion(_ completion: MKLocalSearchCompletion) {
        let request = MKLocalSearch.Request(completion: completion)
        let fallbackName = completion.title
        MKLocalSearch(request: request).start { response, error in
            if let error {
                AppLogger.navigation.error("Local search failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard let item = response?.mapItems.first else { return }
            let coordinate = item.placemark.coordinate
            let name = item.name ?? fallbackName
            Task { @MainActor in
                self.setDestination(coordinate: coordinate, name: name)
            }
        }
    }

    func setDestination(coordinate: CLLocationCoordinate2D, name: String) {
        destinationCoordinate = coordinate
        destinationName = name
        searchResults = []
        searchQuery = ""
        computeRoute(isRecalculation: false)
    }

    enum PetrolSearchOutcome: Sendable {
        case found
        case noneNearby
        case allClosed
    }

    private static let overpassEndpoints = [
        "https://lz4.overpass-api.de/api/interpreter",
        "https://z.overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
        "https://overpass-api.de/api/interpreter"
    ]

    /// Search nearby fuel stations, preferring ones that are open now (OSM `opening_hours`
    /// via Overpass). MapKit does not expose business hours, so closed Apple Maps POIs
    /// alone cannot be filtered — OSM is the source of truth for hours.
    func navigateToNearestPetrol(completion: ((PetrolSearchOutcome) -> Void)? = nil) {
        guard let origin else {
            completion?(.noneNearby)
            return
        }
        Task {
            let outcome = await self.findOpenPetrolStation(near: origin)
            completion?(outcome)
        }
    }

    private struct PetrolCandidate {
        let name: String
        let coordinate: CLLocationCoordinate2D
        let distance: CLLocationDistance
        let status: OpeningHoursEvaluator.Status
    }

    private func findOpenPetrolStation(near origin: CLLocationCoordinate2D) async -> PetrolSearchOutcome {
        let here = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let osmStations = await fetchOSMFuelStations(near: origin, radiusMeters: 15_000)

        if !osmStations.isEmpty {
            let candidates: [PetrolCandidate] = osmStations.map { station in
                let distance = here.distance(
                    from: CLLocation(latitude: station.coordinate.latitude, longitude: station.coordinate.longitude)
                )
                return PetrolCandidate(
                    name: station.name,
                    coordinate: station.coordinate,
                    distance: distance,
                    status: OpeningHoursEvaluator.status(of: station.openingHours)
                )
            }.sorted { $0.distance < $1.distance }

            let open = candidates.filter { $0.status == .open }
            let unknown = candidates.filter { $0.status == .unknown }
            let closed = candidates.filter { $0.status == .closed }

            if let best = open.first {
                AppLogger.navigation.notice(
                    "Petrol (open): \(best.name, privacy: .public) \(Int(best.distance))m"
                )
                setDestination(coordinate: best.coordinate, name: best.name)
                return .found
            }

            // No confirmed-open station — use nearest with unknown hours rather than a closed one.
            if let best = unknown.first {
                AppLogger.navigation.notice(
                    "Petrol (hours unknown): \(best.name, privacy: .public) \(Int(best.distance))m — skipped \(closed.count) closed"
                )
                setDestination(coordinate: best.coordinate, name: best.name)
                return .found
            }

            if !closed.isEmpty {
                AppLogger.navigation.notice("All \(closed.count) nearby OSM petrol stations appear closed")
                return .allClosed
            }
        }

        // Overpass empty/failed — MapKit fallback (cannot verify hours).
        AppLogger.navigation.info("Petrol Overpass empty — falling back to MapKit POI search")
        return await findPetrolViaMapKit(near: origin)
    }

    private struct OSMFuelStation {
        let name: String
        let coordinate: CLLocationCoordinate2D
        let openingHours: String?
    }

    private func fetchOSMFuelStations(
        near origin: CLLocationCoordinate2D,
        radiusMeters: Int
    ) async -> [OSMFuelStation] {
        let query = """
        [out:json][timeout:20];
        (
          node["amenity"="fuel"](around:\(radiusMeters),\(origin.latitude),\(origin.longitude));
          way["amenity"="fuel"](around:\(radiusMeters),\(origin.latitude),\(origin.longitude));
        );
        out center tags;
        """

        guard let body = "data=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)"
            .data(using: .utf8) else { return [] }

        for endpoint in Self.overpassEndpoints {
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 20

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    AppLogger.navigation.warning("Petrol Overpass HTTP \(http.statusCode) from \(endpoint)")
                    continue
                }
                return parseOSMFuelStations(from: data)
            } catch {
                AppLogger.navigation.warning(
                    "Petrol Overpass \(endpoint) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return []
    }

    private func parseOSMFuelStations(from data: Data) -> [OSMFuelStation] {
        struct OverpassResponse: Decodable {
            struct Element: Decodable {
                struct Center: Decodable {
                    let lat: Double
                    let lon: Double
                }
                let type: String
                let lat: Double?
                let lon: Double?
                let center: Center?
                let tags: [String: String]?
            }
            let elements: [Element]
        }

        guard let decoded = try? JSONDecoder().decode(OverpassResponse.self, from: data) else {
            AppLogger.navigation.warning("Petrol Overpass JSON decode failed")
            return []
        }

        return decoded.elements.compactMap { element in
            let lat = element.lat ?? element.center?.lat
            let lon = element.lon ?? element.center?.lon
            guard let lat, let lon else { return nil }
            let tags = element.tags ?? [:]
            let brand = tags["brand"]
            let name = tags["name"] ?? brand ?? "Petrol station"
            let display: String
            if let brand, let nameTag = tags["name"], brand != nameTag {
                display = "\(brand) · \(nameTag)"
            } else {
                display = name
            }
            return OSMFuelStation(
                name: display,
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                openingHours: tags["opening_hours"]
            )
        }
    }

    private func findPetrolViaMapKit(near origin: CLLocationCoordinate2D) async -> PetrolSearchOutcome {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "gas station"
        request.resultTypes = .pointOfInterest
        request.region = MKCoordinateRegion(
            center: origin,
            latitudinalMeters: 20_000,
            longitudinalMeters: 20_000
        )

        do {
            let response = try await MKLocalSearch(request: request).start()
            let here = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
            let best = response.mapItems
                .map { item -> (MKMapItem, CLLocationDistance) in
                    let coord = item.placemark.coordinate
                    let distance = here.distance(
                        from: CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                    )
                    return (item, distance)
                }
                .sorted { $0.1 < $1.1 }
                .first

            guard let best else { return .noneNearby }
            let name = best.0.name ?? "Petrol station"
            setDestination(coordinate: best.0.placemark.coordinate, name: name)
            return .found
        } catch {
            AppLogger.navigation.error("Petrol MapKit search failed: \(error.localizedDescription, privacy: .public)")
            return .noneNearby
        }
    }

    func openInAppleMaps() {
        guard let destinationCoordinate else { return }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: destinationCoordinate))
        item.name = destinationName
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }

    func clear() {
        destinationCoordinate = nil
        destinationName = nil
        routeCoordinates = []
        distanceRemaining = 0
        eta = nil
        steps = []
        currentStepIndex = 0
        distanceToNextManeuver = 0
        totalRouteDistance = 0
        totalTravelTime = 0
        isRouting = false
        isOffRoute = false
        isRecalculating = false
        nearestRouteDistance = 0
        searchQuery = ""
        searchResults = []
        onRouteCleared?()
        AppLogger.navigation.notice("Navigation cleared")
    }

    private func computeRoute(isRecalculation: Bool) {
        guard let origin, let destinationCoordinate else { return }
        if isRecalculation {
            isRecalculating = true
        } else {
            isRouting = true
        }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destinationCoordinate))
        request.transportType = .automobile

        MKDirections(request: request).calculate { response, error in
            if let error {
                AppLogger.navigation.error("Directions failed: \(error.localizedDescription, privacy: .public)")
            }
            let route = response?.routes.first
            let coordinates = route?.polyline.coordinates ?? []
            let distance = route?.distance ?? 0
            let travelTime = route?.expectedTravelTime ?? 0
            let navSteps: [NavStep] = (route?.steps ?? []).compactMap { step in
                let instruction = step.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !instruction.isEmpty else { return nil }
                let coords = step.polyline.coordinates
                let end = coords.last ?? step.polyline.coordinate
                return NavStep(instruction: instruction, distance: step.distance, endCoordinate: end)
            }
            Task { @MainActor in
                self.applyRoute(
                    coordinates: coordinates,
                    distance: distance,
                    travelTime: travelTime,
                    steps: navSteps,
                    isRecalculation: isRecalculation
                )
            }
        }
    }

    private func applyRoute(
        coordinates: [CLLocationCoordinate2D],
        distance: CLLocationDistance,
        travelTime: TimeInterval,
        steps: [NavStep],
        isRecalculation: Bool
    ) {
        routeCoordinates = coordinates
        totalRouteDistance = distance
        totalTravelTime = travelTime
        distanceRemaining = distance
        eta = travelTime > 0 ? Date().addingTimeInterval(travelTime) : nil
        self.steps = steps
        currentStepIndex = 0
        distanceToNextManeuver = steps.first?.distance ?? distance
        isRouting = false
        isRecalculating = false
        isOffRoute = false
        nearestRouteDistance = 0
        if isRecalculation {
            lastRecalculateAt = Date()
        }
        AppLogger.navigation.notice(
            "Route \(isRecalculation ? "recalculated" : "computed"): \(Int(distance))m, \(steps.count) steps"
        )
        onRouteApplied?(coordinates, travelTime)
    }

    private func recomputeRemaining(from coordinate: CLLocationCoordinate2D) {
        guard routeCoordinates.count > 1 else { return }
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        var nearestIndex = 0
        var nearestDistance = Double.greatestFiniteMagnitude
        for (index, coord) in routeCoordinates.enumerated() {
            let distance = here.distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
            if distance < nearestDistance {
                nearestDistance = distance
                nearestIndex = index
            }
        }
        nearestRouteDistance = nearestDistance

        var remaining = nearestDistance
        if nearestIndex < routeCoordinates.count - 1 {
            for index in nearestIndex..<(routeCoordinates.count - 1) {
                let a = routeCoordinates[index]
                let b = routeCoordinates[index + 1]
                remaining += CLLocation(latitude: a.latitude, longitude: a.longitude)
                    .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            }
        }

        distanceRemaining = remaining
        if totalRouteDistance > 0, totalTravelTime > 0 {
            let fraction = min(max(remaining / totalRouteDistance, 0), 1)
            eta = Date().addingTimeInterval(totalTravelTime * fraction)
        }
    }

    private func advanceStepIfNeeded(from coordinate: CLLocationCoordinate2D) {
        guard let step = currentStep else {
            distanceToNextManeuver = distanceRemaining
            return
        }

        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let toEnd = here.distance(
            from: CLLocation(latitude: step.endCoordinate.latitude, longitude: step.endCoordinate.longitude)
        )
        distanceToNextManeuver = toEnd

        // Advance while we're near the maneuver point (and not on the last step).
        var index = currentStepIndex
        while index < steps.count {
            let candidate = steps[index]
            let distance = here.distance(
                from: CLLocation(
                    latitude: candidate.endCoordinate.latitude,
                    longitude: candidate.endCoordinate.longitude
                )
            )
            if distance <= Self.stepAdvanceMeters, index < steps.count - 1 {
                index += 1
                continue
            }
            break
        }

        if index != currentStepIndex {
            currentStepIndex = index
            if let next = currentStep {
                distanceToNextManeuver = here.distance(
                    from: CLLocation(
                        latitude: next.endCoordinate.latitude,
                        longitude: next.endCoordinate.longitude
                    )
                )
                AppLogger.navigation.info("Advanced to step \(index + 1)/\(self.steps.count): \(next.instruction, privacy: .public)")
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func checkOffRouteAndRecalculate(from coordinate: CLLocationCoordinate2D) {
        guard hasDestination, hasRoute, !isRouting, !isRecalculating else { return }

        if nearestRouteDistance > Self.offRouteThresholdMeters {
            isOffRoute = true
            let now = Date()
            guard now.timeIntervalSince(lastRecalculateAt) >= Self.recalculateCooldown else { return }
            lastRecalculateAt = now
            AppLogger.navigation.notice(
                "Off route (\(Int(self.nearestRouteDistance))m) — recalculating"
            )
            computeRoute(isRecalculation: true)
        } else if isOffRoute, nearestRouteDistance <= Self.offRouteThresholdMeters / 2 {
            isOffRoute = false
        }
    }

    static func formatDistance(_ meters: CLLocationDistance) -> String {
        if meters >= 1000 {
            return String(format: "%.1f km", meters / 1000)
        }
        return "\(max(0, Int(meters.rounded()))) m"
    }

    // MARK: - MKLocalSearchCompleterDelegate

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            self.searchResults = completer.results
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        AppLogger.navigation.error("Search completer failed: \(error.localizedDescription, privacy: .public)")
    }
}

extension MKPolyline {
    /// Extracts the polyline's vertices as an array of coordinates.
    var coordinates: [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(),
            count: pointCount
        )
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}
