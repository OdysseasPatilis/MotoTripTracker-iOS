import CoreLocation
import Foundation

@Observable
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var isLocationEnabled: Bool
    private(set) var lastLocation: CLLocation?

    var onLocationUpdate: ((CLLocation) -> Void)?

    private var isCollecting = false

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
        isCollecting = true
        refreshLocationEnabled()
        configureBackgroundUpdatesIfAllowed()
        manager.startUpdatingLocation()
    }

    func stopUpdating() {
        isCollecting = false
        manager.allowsBackgroundLocationUpdates = false
        manager.stopUpdatingLocation()
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
            self.authorizationStatus = manager.authorizationStatus
            self.refreshLocationEnabled()
            self.configureBackgroundUpdatesIfAllowed()
            if manager.authorizationStatus == .authorizedWhenInUse {
                manager.requestAlwaysAuthorization()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            guard self.isCollecting else { return }
            self.lastLocation = location
            self.onLocationUpdate?(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Keep collecting; transient GPS failures are expected.
    }
}
