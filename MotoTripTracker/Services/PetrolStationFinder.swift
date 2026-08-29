import CoreLocation
import Foundation
import MapKit
import os

/// A ranked petrol recommendation for the station picker.
struct PetrolStationRecommendation: Identifiable, Hashable {
    let id: UUID
    let name: String
    let brand: String?
    let coordinateLatitude: Double
    let coordinateLongitude: Double
    let distanceMeters: CLLocationDistance
    let openStatus: OpeningHoursEvaluator.Status
    /// Octane grades advertised in OSM tags (95 / 98 / 100, etc.).
    let availableOctanes: Set<Int>
    let openingHoursRaw: String?
    /// On or beside a motorway / trunk (service area or within ~400 m of highway).
    let isHighwayAccessible: Bool

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: coordinateLatitude, longitude: coordinateLongitude)
    }

    var matchesPreferredOctane: Bool {
        // Empty means OSM didn't tag fuels — treat as unknown, not a mismatch.
        !availableOctanes.isEmpty
    }

    func displayOctanes(preferred: Set<Int>) -> String {
        let preferredHits = availableOctanes.intersection(preferred).sorted()
        if !preferredHits.isEmpty {
            return preferredHits.map { "\($0)" }.joined(separator: " · ")
        }
        if availableOctanes.isEmpty { return "Fuel grades unknown" }
        return availableOctanes.sorted().map { "\($0)" }.joined(separator: " · ")
    }

    /// 1–5 stars for how well this station matches brand + octane preferences.
    /// Not Apple Maps ratings — MapKit does not expose those to apps.
    func preferenceMatchStars(preferences: PetrolPreferences) -> Int {
        var stars = 2
        let brandRank = preferences.brandRank(for: brand ?? name)
        if brandRank == 0 {
            stars = 4
        } else if brandRank == 1 {
            stars = 3
        } else if brandRank < Int.max / 2 {
            stars = 2
        }

        let preferred = preferences.preferredOctanes
        if !preferred.isEmpty, !availableOctanes.isEmpty,
           !availableOctanes.isDisjoint(with: preferred) {
            stars = min(5, stars + 1)
        }
        if openStatus == .open {
            stars = min(5, stars + (brandRank == 0 ? 1 : 0))
        }
        return max(1, min(5, stars))
    }

    var hoursSummary: String? {
        OpeningHoursEvaluator.shortLabel(of: openingHoursRaw)
    }
}

/// Adaptive petrol search output for the picker UI.
struct PetrolSearchResult: Sendable {
    let plan: PetrolSearchPlan
    let stations: [PetrolStationFinder.RankedStation]
}

/// Finds nearby petrol stations (OSM), scores them by brand / octane / open status / distance,
/// and attaches MapKit items when possible for Apple place-detail sheets.
@MainActor
final class PetrolStationFinder {
    private static let overpassEndpoints = [
        "https://lz4.overpass-api.de/api/interpreter",
        "https://z.overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
        "https://overpass-api.de/api/interpreter"
    ]

    private static let maxFetchRadiusMeters = 50_000
    private static let motorwayProbeRadiusMeters = 1_200
    private static let highwayProximityMeters: CLLocationDistance = 400

    struct RankedStation: Identifiable {
        var recommendation: PetrolStationRecommendation
        var mapItem: MKMapItem?
        var score: Int

        var id: UUID { recommendation.id }
    }

    func search(
        near origin: CLLocationCoordinate2D,
        preferences: PetrolPreferences,
        speedKmh: Double = 0,
        courseDegrees: Double? = nil,
        includeClosed: Bool = false
    ) async -> PetrolSearchResult {
        let fetch = await fetchOSMData(near: origin, radiusMeters: Self.maxFetchRadiusMeters)
        let mapItems = await fetchMapKitFuelItems(near: origin, radiusMeters: fetch.planRadiusMeters)
        let here = CLLocation(latitude: origin.latitude, longitude: origin.longitude)

        let isNearMotorway = Self.isWithinHighwayProximity(
            coordinate: origin,
            motorways: fetch.motorwaySegments,
            maxMeters: Self.highwayProximityMeters
        )

        let tierRadii = [2_000, 5_000, 10_000, 20_000, Self.maxFetchRadiusMeters]
        let distances = fetch.stations.map { station in
            here.distance(
                from: CLLocation(latitude: station.coordinate.latitude, longitude: station.coordinate.longitude)
            )
        }

        let statuses = fetch.stations.map { OpeningHoursEvaluator.status(of: $0.openingHours) }
        let countableDistances = zip(distances, statuses).compactMap { distance, status -> CLLocationDistance? in
            if !includeClosed, status == .closed { return nil }
            return distance
        }

        let counts = PetrolSearchStrategy.countStations(within: tierRadii, distances: countableDistances)
        let plan = PetrolSearchStrategy.plan(
            origin: origin,
            speedKmh: speedKmh,
            isNearMotorway: isNearMotorway,
            stationCountsByRadius: counts
        )

        var ranked: [RankedStation] = zip(fetch.stations, zip(distances, statuses)).map { station, pair in
            let (distance, status) = pair
            let highwayAccessible = station.isHighwayTagged || Self.isWithinHighwayProximity(
                coordinate: station.coordinate,
                motorways: fetch.motorwaySegments,
                maxMeters: Self.highwayProximityMeters
            )
            let recommendation = PetrolStationRecommendation(
                id: UUID(),
                name: station.displayName,
                brand: station.brand,
                coordinateLatitude: station.coordinate.latitude,
                coordinateLongitude: station.coordinate.longitude,
                distanceMeters: distance,
                openStatus: status,
                availableOctanes: station.octanes,
                openingHoursRaw: station.openingHours,
                isHighwayAccessible: highwayAccessible
            )
            let mapItem = nearestMapItem(to: station.coordinate, in: mapItems, maxMeters: 90)
                ?? makeMapItem(name: station.displayName, coordinate: station.coordinate)
            let score = preferenceScore(
                recommendation,
                preferences: preferences,
                plan: plan,
                origin: origin,
                courseDegrees: courseDegrees
            )
            return RankedStation(recommendation: recommendation, mapItem: mapItem, score: score)
        }

        ranked = ranked.filter { $0.recommendation.distanceMeters <= Double(plan.activeRadiusMeters) }

        if ranked.isEmpty {
            ranked = mapItems
                .map { item -> RankedStation? in
                    let coord = item.placemark.coordinate
                    let distance = here.distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
                    guard distance <= Double(plan.activeRadiusMeters) else { return nil }
                    let recommendation = PetrolStationRecommendation(
                        id: UUID(),
                        name: item.name ?? "Petrol station",
                        brand: nil,
                        coordinateLatitude: coord.latitude,
                        coordinateLongitude: coord.longitude,
                        distanceMeters: distance,
                        openStatus: .unknown,
                        availableOctanes: [],
                        openingHoursRaw: nil,
                        isHighwayAccessible: false
                    )
                    return RankedStation(
                        recommendation: recommendation,
                        mapItem: item,
                        score: preferenceScore(
                            recommendation,
                            preferences: preferences,
                            plan: plan,
                            origin: origin,
                            courseDegrees: courseDegrees
                        )
                    )
                }
                .compactMap { $0 }
        }

        if !includeClosed {
            ranked = ranked.filter { $0.recommendation.openStatus != .closed }
        }

        ranked.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            return lhs.recommendation.distanceMeters < rhs.recommendation.distanceMeters
        }

        return PetrolSearchResult(plan: plan, stations: ranked)
    }

    func recommendations(
        near origin: CLLocationCoordinate2D,
        preferences: PetrolPreferences,
        speedKmh: Double = 0,
        courseDegrees: Double? = nil,
        includeClosed: Bool = false
    ) async -> [RankedStation] {
        await search(
            near: origin,
            preferences: preferences,
            speedKmh: speedKmh,
            courseDegrees: courseDegrees,
            includeClosed: includeClosed
        ).stations
    }

    /// Lower is better.
    private func preferenceScore(
        _ station: PetrolStationRecommendation,
        preferences: PetrolPreferences,
        plan: PetrolSearchPlan,
        origin: CLLocationCoordinate2D,
        courseDegrees: Double?
    ) -> Int {
        var score = 0
        score += preferences.brandRank(for: station.brand ?? station.name) * 1_000

        let preferred = preferences.preferredOctanes
        if preferred.isEmpty {
            // no octane preference
        } else if station.availableOctanes.isEmpty {
            score += 200 // unknown grades
        } else if station.availableOctanes.isDisjoint(with: preferred) {
            score += 500 // known mismatch
        } else {
            score += 0 // has at least one preferred grade
        }

        switch station.openStatus {
        case .open: score += 0
        case .unknown: score += 50
        case .closed: score += 5_000
        }

        if plan.prioritizeHighway {
            if station.isHighwayAccessible {
                score -= 800
            } else {
                score += 350
            }

            if let courseDegrees, courseDegrees >= 0 {
                let bearing = Self.bearing(from: origin, to: station.coordinate)
                let delta = Self.angularDifference(bearing, courseDegrees)
                if delta <= 55 {
                    score -= 250
                } else if delta >= 120 {
                    score += 200
                }
            }
        }

        // Soft distance penalty so a slightly farther preferred brand still wins.
        score += Int(min(station.distanceMeters, 20_000) / 50)
        return score
    }

    private func nearestMapItem(
        to coordinate: CLLocationCoordinate2D,
        in items: [MKMapItem],
        maxMeters: CLLocationDistance
    ) -> MKMapItem? {
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return items
            .map { item -> (MKMapItem, CLLocationDistance) in
                let c = item.placemark.coordinate
                let d = here.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
                return (item, d)
            }
            .filter { $0.1 <= maxMeters }
            .sorted { $0.1 < $1.1 }
            .first?
            .0
    }

    private func makeMapItem(name: String, coordinate: CLLocationCoordinate2D) -> MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = name
        return item
    }

    // MARK: - Geometry

    private static func bearing(from origin: CLLocationCoordinate2D, to target: CLLocationCoordinate2D) -> Double {
        let lat1 = origin.latitude * .pi / 180
        let lat2 = target.latitude * .pi / 180
        let dLon = (target.longitude - origin.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let radians = atan2(y, x)
        let degrees = radians * 180 / .pi
        return degrees >= 0 ? degrees : degrees + 360
    }

    private static func angularDifference(_ a: Double, _ b: Double) -> Double {
        let diff = abs(a - b).truncatingRemainder(dividingBy: 360)
        return diff > 180 ? 360 - diff : diff
    }

    private static func isWithinHighwayProximity(
        coordinate: CLLocationCoordinate2D,
        motorways: [MotorwaySegment],
        maxMeters: CLLocationDistance
    ) -> Bool {
        let point = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        for segment in motorways {
            guard segment.coordinates.count >= 2 else { continue }
            for index in 0..<(segment.coordinates.count - 1) {
                let start = segment.coordinates[index]
                let end = segment.coordinates[index + 1]
                if distance(from: point, toSegmentBetween: start, and: end) <= maxMeters {
                    return true
                }
            }
        }
        return false
    }

    private static func distance(
        from point: CLLocation,
        toSegmentBetween start: CLLocationCoordinate2D,
        and end: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        let startLoc = CLLocation(latitude: start.latitude, longitude: start.longitude)
        let endLoc = CLLocation(latitude: end.latitude, longitude: end.longitude)
        let segmentLength = startLoc.distance(from: endLoc)
        guard segmentLength > 0 else {
            return point.distance(from: startLoc)
        }

        let t = max(
            0,
            min(
                1,
                (
                    (point.coordinate.latitude - start.latitude) * (end.latitude - start.latitude)
                        + (point.coordinate.longitude - start.longitude) * (end.longitude - start.longitude)
                )
                    / (
                        pow(end.latitude - start.latitude, 2)
                            + pow(end.longitude - start.longitude, 2)
                    )
            )
        )

        let projLat = start.latitude + t * (end.latitude - start.latitude)
        let projLon = start.longitude + t * (end.longitude - start.longitude)
        let projection = CLLocation(latitude: projLat, longitude: projLon)
        return point.distance(from: projection)
    }

    // MARK: - OSM

    private struct OSMFuelStation {
        let name: String?
        let brand: String?
        let coordinate: CLLocationCoordinate2D
        let openingHours: String?
        let octanes: Set<Int>
        let isHighwayTagged: Bool

        var displayName: String {
            if let brand, let name, brand != name { return "\(brand) · \(name)" }
            return brand ?? name ?? "Petrol station"
        }
    }

    private struct MotorwaySegment {
        let coordinates: [CLLocationCoordinate2D]
    }

    private struct OSMFetchResult {
        let stations: [OSMFuelStation]
        let motorwaySegments: [MotorwaySegment]
        let planRadiusMeters: Int
    }

    private func fetchOSMData(near origin: CLLocationCoordinate2D, radiusMeters: Int) async -> OSMFetchResult {
        let query = """
        [out:json][timeout:25];
        (
          node["amenity"="fuel"](around:\(radiusMeters),\(origin.latitude),\(origin.longitude));
          way["amenity"="fuel"](around:\(radiusMeters),\(origin.latitude),\(origin.longitude));
        );
        out center tags;
        way["highway"~"^(motorway|trunk|motorway_link|trunk_link)$"](around:\(Self.motorwayProbeRadiusMeters),\(origin.latitude),\(origin.longitude));
        out geom;
        """

        guard let body = "data=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)"
            .data(using: .utf8) else {
            return OSMFetchResult(stations: [], motorwaySegments: [], planRadiusMeters: radiusMeters)
        }

        for endpoint in Self.overpassEndpoints {
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 25

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    AppLogger.navigation.warning("Petrol Overpass HTTP \(http.statusCode) from \(endpoint)")
                    continue
                }
                let parsed = parseOSMResponse(from: data)
                AppLogger.navigation.notice(
                    "Petrol OSM returned \(parsed.stations.count) stations, \(parsed.motorwaySegments.count) motorway segments"
                )
                return OSMFetchResult(
                    stations: parsed.stations,
                    motorwaySegments: parsed.motorwaySegments,
                    planRadiusMeters: radiusMeters
                )
            } catch {
                AppLogger.navigation.warning(
                    "Petrol Overpass \(endpoint) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return OSMFetchResult(stations: [], motorwaySegments: [], planRadiusMeters: radiusMeters)
    }

    private func parseOSMResponse(from data: Data) -> (stations: [OSMFuelStation], motorwaySegments: [MotorwaySegment]) {
        struct OverpassResponse: Decodable {
            struct Element: Decodable {
                struct Center: Decodable { let lat: Double; let lon: Double }
                struct GeometryPoint: Decodable { let lat: Double; let lon: Double }
                let type: String?
                let lat: Double?
                let lon: Double?
                let center: Center?
                let tags: [String: String]?
                let geometry: [GeometryPoint]?
            }
            let elements: [Element]
        }

        guard let decoded = try? JSONDecoder().decode(OverpassResponse.self, from: data) else {
            return ([], [])
        }

        var stations: [OSMFuelStation] = []
        var motorways: [MotorwaySegment] = []

        for element in decoded.elements {
            if element.type == "way", let geometry = element.geometry, !geometry.isEmpty, element.tags?["amenity"] != "fuel" {
                let coords = geometry.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                motorways.append(MotorwaySegment(coordinates: coords))
                continue
            }

            let lat = element.lat ?? element.center?.lat
            let lon = element.lon ?? element.center?.lon
            guard let lat, let lon else { continue }
            let tags = element.tags ?? [:]
            guard tags["amenity"] == "fuel" else { continue }

            stations.append(
                OSMFuelStation(
                    name: tags["name"],
                    brand: tags["brand"] ?? tags["operator"],
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    openingHours: tags["opening_hours"],
                    octanes: Self.parseOctanes(from: tags),
                    isHighwayTagged: Self.isHighwayTagged(tags)
                )
            )
        }

        return (stations, motorways)
    }

    private static func isHighwayTagged(_ tags: [String: String]) -> Bool {
        let motorway = tags["motorway"]?.lowercased()
        if motorway == "yes" || motorway == "designated" { return true }
        if tags["highway"]?.lowercased() == "rest_area" { return true }
        if tags["access"]?.lowercased() == "motorway" { return true }
        return false
    }

    /// Reads common OSM fuel grade tags into octane numbers.
    static func parseOctanes(from tags: [String: String]) -> Set<Int> {
        var result = Set<Int>()
        let truthy: Set<String> = ["yes", "true", "1", "ok"]

        func consider(key: String, octane: Int) {
            if let value = tags[key]?.lowercased(), truthy.contains(value) || value == String(octane) {
                result.insert(octane)
            }
        }

        consider(key: "fuel:octane_95", octane: 95)
        consider(key: "fuel:octane_98", octane: 98)
        consider(key: "fuel:octane_100", octane: 100)
        consider(key: "fuel:95", octane: 95)
        consider(key: "fuel:98", octane: 98)
        consider(key: "fuel:100", octane: 100)

        for (key, value) in tags {
            guard key.hasPrefix("fuel:octane_"), truthy.contains(value.lowercased()) || value == "yes" else { continue }
            let suffix = key.replacingOccurrences(of: "fuel:octane_", with: "")
            if let octane = Int(suffix) { result.insert(octane) }
        }
        return result
    }

    // MARK: - MapKit

    private func fetchMapKitFuelItems(near origin: CLLocationCoordinate2D, radiusMeters: Int) async -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "gas station"
        request.resultTypes = .pointOfInterest
        let span = Double(max(radiusMeters, 5_000))
        request.region = MKCoordinateRegion(
            center: origin,
            latitudinalMeters: span,
            longitudinalMeters: span
        )
        do {
            let response = try await MKLocalSearch(request: request).start()
            return response.mapItems
        } catch {
            AppLogger.navigation.warning("Petrol MapKit enrich failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
