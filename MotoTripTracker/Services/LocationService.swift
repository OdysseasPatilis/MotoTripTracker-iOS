import CoreLocation
import Foundation
import os

@Observable
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    private(set) var isLocationEnabled = false
    private(set) var lastLocation: CLLocation?

    /// Monotonic counter bumped on every fix. `CLLocation` is not `Equatable`, so views
    /// observe this instead to react to new locations (e.g. to drive a follow camera).
    private(set) var updateTick: Int = 0

    var onLocationUpdate: ((CLLocation) -> Void)?

    private var isUpdating = false

    override init() {
        super.init()
        // Don't call locationServicesEnabled() — Apple warns it can block the main thread.
        // Prefer locationManagerDidChangeAuthorization: + authorizationStatus.
        let status = manager.authorizationStatus
        authorizationStatus = status
        isLocationEnabled = Self.isAuthorized(status)
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
    }

    func requestAuthorization() {
        AppLogger.location.info(
            "Requesting location authorization (current=\(String(describing: self.authorizationStatus)))"
        )
        switch authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    func startUpdating() {
        guard !isUpdating else {
            configureBackgroundUpdatesIfAllowed()
            startIfAuthorized()
            return
        }
        isUpdating = true
        configureBackgroundUpdatesIfAllowed()
        startIfAuthorized()
        AppLogger.location.notice(
            "Location updates requested (authorized=\(self.isLocationEnabled), background=\(self.manager.allowsBackgroundLocationUpdates))"
        )
    }

    func stopUpdating() {
        guard isUpdating else { return }
        isUpdating = false
        manager.allowsBackgroundLocationUpdates = false
        manager.stopUpdatingLocation()
        AppLogger.location.notice("Location updates stopped")
    }

    func refreshLocationEnabled() {
        isLocationEnabled = Self.isAuthorized(authorizationStatus)
    }

    private func startIfAuthorized() {
        guard isUpdating, isLocationEnabled else { return }
        manager.startUpdatingLocation()
    }

    private func configureBackgroundUpdatesIfAllowed() {
        // Setting this without Always authorization crashes.
        manager.allowsBackgroundLocationUpdates = (authorizationStatus == .authorizedAlways)
    }

    private static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedAlways || status == .authorizedWhenInUse
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let status = manager.authorizationStatus
            AppLogger.location.notice("Authorization changed → \(String(describing: status))")
            self.authorizationStatus = status
            self.refreshLocationEnabled()
            self.configureBackgroundUpdatesIfAllowed()
            if status == .authorizedWhenInUse {
                manager.requestAlwaysAuthorization()
            }
            self.startIfAuthorized()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            guard self.isUpdating else { return }
            self.lastLocation = location
            self.updateTick &+= 1
            if LogThrottle.shouldLog(key: "location.update", interval: 30) {
                AppLogger.location.debug(
                    "Fix @ \(AppLogger.coordinate(location.coordinate.latitude, location.coordinate.longitude), privacy: .public) acc=\(location.horizontalAccuracy, format: .fixed(precision: 1))m spd=\(max(0, location.speed) * 3.6, format: .fixed(precision: 0))km/h"
                )
            }
            self.onLocationUpdate?(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            AppLogger.location.error("Location error: \(error.localizedDescription, privacy: .public)")
        }
    }
}
