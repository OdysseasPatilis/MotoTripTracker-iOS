import CoreLocation
import Foundation
import MapKit
import os

extension NavigationService {
    enum PetrolSearchOutcome: Sendable {
        case found
        case noneNearby
        case allClosed
    }

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

    fileprivate struct PetrolCandidate {
        let name: String
        let coordinate: CLLocationCoordinate2D
        let distance: CLLocationDistance
        let status: OpeningHoursEvaluator.Status
    }

    fileprivate struct OSMFuelStation {
        let name: String
        let coordinate: CLLocationCoordinate2D
        let openingHours: String?
    }

    private static let overpassEndpoints = [
        "https://lz4.overpass-api.de/api/interpreter",
        "https://z.overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
        "https://overpass-api.de/api/interpreter"
    ]

    fileprivate func findOpenPetrolStation(near origin: CLLocationCoordinate2D) async -> PetrolSearchOutcome {
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

    fileprivate func fetchOSMFuelStations(
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

    fileprivate func parseOSMFuelStations(from data: Data) -> [OSMFuelStation] {
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

    fileprivate func findPetrolViaMapKit(near origin: CLLocationCoordinate2D) async -> PetrolSearchOutcome {
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
                    let coord = MapKitPlace.coordinate(of: item)
                    let distance = here.distance(
                        from: CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                    )
                    return (item, distance)
                }
                .sorted { $0.1 < $1.1 }
                .first

            guard let best else { return .noneNearby }
            let name = best.0.name ?? "Petrol station"
            setDestination(coordinate: MapKitPlace.coordinate(of: best.0), name: name)
            return .found
        } catch {
            AppLogger.navigation.error("Petrol MapKit search failed: \(error.localizedDescription, privacy: .public)")
            return .noneNearby
        }
    }
}
