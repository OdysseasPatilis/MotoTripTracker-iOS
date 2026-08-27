import CoreLocation
import Foundation
import os

@Observable
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var isLocationEnabled: Bool
    private(set) var lastLocation: CLLocation?

    var onLocationUpdate: ((CLLocation) -> Void)?

    private var isUpdating = false

    override init() {
        authorizationStatus = manager.authorizationStatus
        isLocationEnabled = CLLocationManager.locationServicesEnabled()
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
    }

    func requestAuthorization() {
        AppLogger.location.info("Requesting location authorization (current=\(String(describing: self.manager.authorizationStatus)))")
        switch manager.authorizationStatus {
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
            return
        }
        isUpdating = true
        refreshLocationEnabled()
        configureBackgroundUpdatesIfAllowed()
        manager.startUpdatingLocation()
        AppLogger.location.notice("Location updates started (background=\(self.manager.allowsBackgroundLocationUpdates))")
    }

    func stopUpdating() {
        guard isUpdating else { return }
        isUpdating = false
        manager.allowsBackgroundLocationUpdates = false
        manager.stopUpdatingLocation()
        AppLogger.location.notice("Location updates stopped")
    }

    func refreshLocationEnabled() {
        isLocationEnabled = CLLocationManager.locationServicesEnabled()
            && (authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse)
    }

    private func configureBackgroundUpdatesIfAllowed() {
        // Setting this without Always authorization crashes.
        manager.allowsBackgroundLocationUpdates = (authorizationStatus == .authorizedAlways)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let status = manager.authorizationStatus
            AppLogger.location.notice("Authorization changed → \(String(describing: status))")
            self.authorizationStatus = status
            self.refreshLocationEnabled()
            self.configureBackgroundUpdatesIfAllowed()
            if manager.authorizationStatus == .authorizedWhenInUse {
                manager.requestAlwaysAuthorization()
            }
            if self.isLocationEnabled, self.isUpdating {
                manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            guard self.isUpdating else { return }
            self.lastLocation = location
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
