import CoreLocation
import Foundation
import MapKit
import os

/// A single turn-by-turn maneuver. Kept as a `Sendable` value type (instead of
/// holding `MKRoute.Step`) so route results can cross the concurrency boundary
/// out of MapKit completion handlers. Consumed by the Phase B turn-by-turn HUD.
struct NavStep: Sendable, Identifiable, Hashable {
    let id = UUID()
    let instruction: String
    let distance: CLLocationDistance
}

/// Destination search + route planning for the ride dashboard.
///
/// Phase A (shipping): search a destination, compute a driving route, draw it on
/// the map, and surface remaining distance / ETA plus an "Open in Apple Maps"
/// handoff. Phase B (scaffolded via `steps` / `currentStepIndex`) will add
/// in-app turn-by-turn advancement without a rewrite.
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

    // Phase B turn-by-turn scaffold.
    private(set) var steps: [NavStep] = []
    var currentStepIndex: Int = 0

    private let completer = MKLocalSearchCompleter()
    private var origin: CLLocationCoordinate2D?
    private var totalRouteDistance: CLLocationDistance = 0
    private var totalTravelTime: TimeInterval = 0

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    var hasDestination: Bool { destinationCoordinate != nil }
    var hasRoute: Bool { routeCoordinates.count > 1 }

    var summaryText: String {
        let distanceString: String
        if distanceRemaining >= 1000 {
            distanceString = String(format: "%.1f km", distanceRemaining / 1000)
        } else {
            distanceString = "\(Int(distanceRemaining.rounded())) m"
        }
        guard let eta else { return distanceString }
        return "\(distanceString) · ETA \(eta.formatted(date: .omitted, time: .shortened))"
    }

    /// Called on every GPS fix. Keeps search results locally relevant and, when a
    /// route is active, recomputes remaining distance / ETA.
    func updateOrigin(_ coordinate: CLLocationCoordinate2D) {
        origin = coordinate
        completer.region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 60_000,
            longitudinalMeters: 60_000
        )
        recomputeRemaining(from: coordinate)
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
        computeRoute()
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
        totalRouteDistance = 0
        totalTravelTime = 0
        searchQuery = ""
        searchResults = []
        AppLogger.navigation.notice("Navigation cleared")
    }

    private func computeRoute() {
        guard let origin, let destinationCoordinate else { return }
        isRouting = true
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
            let navSteps: [NavStep] = (route?.steps ?? [])
                .filter { !$0.instructions.isEmpty }
                .map { NavStep(instruction: $0.instructions, distance: $0.distance) }
            Task { @MainActor in
                self.applyRoute(
                    coordinates: coordinates,
                    distance: distance,
                    travelTime: travelTime,
                    steps: navSteps
                )
            }
        }
    }

    private func applyRoute(
        coordinates: [CLLocationCoordinate2D],
        distance: CLLocationDistance,
        travelTime: TimeInterval,
        steps: [NavStep]
    ) {
        routeCoordinates = coordinates
        totalRouteDistance = distance
        totalTravelTime = travelTime
        distanceRemaining = distance
        eta = travelTime > 0 ? Date().addingTimeInterval(travelTime) : nil
        self.steps = steps
        currentStepIndex = 0
        isRouting = false
        AppLogger.navigation.notice(
            "Route computed: \(Int(distance))m, \(Int(travelTime))s, \(steps.count) steps"
        )
    }

    /// Lightweight remaining-distance estimate: snap to the nearest route vertex
    /// and sum the remaining segment lengths. ETA is scaled proportionally.
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
