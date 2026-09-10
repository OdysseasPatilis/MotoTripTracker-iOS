import CoreLocation
import Foundation
import os

/// Reverse-geocodes the rider’s ISO country with a distance/time cache.
@MainActor
final class TrafficCameraCountryResolver {
    private let geocoder: CLGeocoder
    private var lastLocation: CLLocation?
    private var lastResolvedAt: Date?
    private var lastCountryCode: String?

    private let minDistanceMeters: CLLocationDistance
    private let minInterval: TimeInterval

    init(
        geocoder: CLGeocoder = CLGeocoder(),
        minDistanceMeters: CLLocationDistance = 5_000,
        minInterval: TimeInterval = 600
    ) {
        self.geocoder = geocoder
        self.minDistanceMeters = minDistanceMeters
        self.minInterval = minInterval
    }

    /// Returns uppercase ISO 3166-1 alpha-2, or nil if unknown.
    func resolve(location: CLLocation) async -> String? {
        let now = Date()
        if let lastCountryCode,
           !Self.shouldRefresh(
            lastLocation: lastLocation,
            lastResolvedAt: lastResolvedAt,
            newLocation: location,
            now: now,
            minDistanceMeters: minDistanceMeters,
            minInterval: minInterval
           ) {
            return lastCountryCode
        }

        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            let code = placemarks.first?.isoCountryCode?.uppercased()
            lastLocation = location
            lastResolvedAt = now
            lastCountryCode = code
            return code
        } catch {
            AppLogger.trafficCamera.warning(
                "Country geocode failed: \(error.localizedDescription, privacy: .public)"
            )
            return lastCountryCode
        }
    }

    nonisolated static func shouldRefresh(
        lastLocation: CLLocation?,
        lastResolvedAt: Date?,
        newLocation: CLLocation,
        now: Date,
        minDistanceMeters: CLLocationDistance = 5_000,
        minInterval: TimeInterval = 600
    ) -> Bool {
        guard let lastLocation, let lastResolvedAt else { return true }
        let moved = newLocation.distance(from: lastLocation) >= minDistanceMeters
        let waited = now.timeIntervalSince(lastResolvedAt) >= minInterval
        return moved || waited
    }
}
