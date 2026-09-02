import CoreLocation
import Foundation
import os
import UIKit

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
    /// Only true during an active ride — never opt into background GPS on the idle dashboard.
    private var wantsBackgroundUpdates = false
    /// Keeps Core Location delivering fixes while the screen is locked (iOS 17+).
    private var backgroundActivitySession: CLBackgroundActivitySession?

    /// Background ride recording only works with Always authorization.
    var hasAlwaysAuthorization: Bool {
        authorizationStatus == .authorizedAlways
    }

    override init() {
        super.init()
        // Don't call locationServicesEnabled() — Apple warns it can block the main thread.
        // Prefer locationManagerDidChangeAuthorization: + authorizationStatus.
        let status = manager.authorizationStatus
        authorizationStatus = status
        isLocationEnabled = Self.isAuthorized(status)
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        applyBackgroundConfiguration(restartIfNeeded: false)
    }

    /// Ask for When In Use only (first launch / dashboard). Never auto-prompts Always.
    func requestWhenInUseIfNeeded() {
        guard authorizationStatus == .notDetermined else { return }
        AppLogger.location.info("Requesting When In Use location authorization")
        manager.requestWhenInUseAuthorization()
    }

    /// Upgrade to Always when the rider explicitly wants background recording.
    func requestAlwaysForRideRecording() {
        AppLogger.location.info(
            "Requesting Always authorization (current=\(String(describing: self.authorizationStatus)))"
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

    func openSystemLocationSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Foreground-only GPS (dashboard map, speed limit warm-up).
    func startUpdating() {
        wantsBackgroundUpdates = false
        endBackgroundActivitySession()
        beginUpdatingIfNeeded()
    }

    /// GPS for an active ride — background updates only when Always is granted.
    func startRideUpdating() {
        wantsBackgroundUpdates = true
        if !Self.hasLocationBackgroundMode {
            AppLogger.location.error(
                "UIBackgroundModes/location missing from Info.plist — screen-lock recording cannot work"
            )
        }
        beginUpdatingIfNeeded()
        ensureBackgroundActivitySession()
    }

    /// Re-assert ride GPS before the app is suspended (e.g. screen lock).
    func reinforceRideUpdating() {
        guard wantsBackgroundUpdates else { return }
        ensureBackgroundActivitySession()
        applyBackgroundConfiguration(restartIfNeeded: true)
        startIfAuthorized()
        AppLogger.location.debug(
            "Ride GPS reinforced (always=\(self.hasAlwaysAuthorization), background=\(self.manager.allowsBackgroundLocationUpdates))"
        )
    }

    func stopUpdating() {
        guard isUpdating else {
            endBackgroundActivitySession()
            return
        }
        isUpdating = false
        wantsBackgroundUpdates = false
        manager.stopUpdatingLocation()
        endBackgroundActivitySession()
        applyBackgroundConfiguration(restartIfNeeded: false)
        AppLogger.location.notice("Location updates stopped")
    }

    func refreshLocationEnabled() {
        isLocationEnabled = Self.isAuthorized(authorizationStatus)
    }

    private func beginUpdatingIfNeeded() {
        let starting = !isUpdating
        isUpdating = true
        applyBackgroundConfiguration(restartIfNeeded: starting)
        startIfAuthorized()
        AppLogger.location.notice(
            "Location updates requested (authorized=\(self.isLocationEnabled), always=\(self.hasAlwaysAuthorization), background=\(self.manager.allowsBackgroundLocationUpdates), ride=\(self.wantsBackgroundUpdates))"
        )
    }

    private func startIfAuthorized() {
        guard isUpdating, isLocationEnabled else { return }
        manager.startUpdatingLocation()
    }

    /// Configures background location safely. Setting `allowsBackgroundLocationUpdates = true`
    /// without Always auth triggers: `!stayUp || CLClientIsBackgroundable(...)`.
    private func applyBackgroundConfiguration(restartIfNeeded: Bool) {
        let status = manager.authorizationStatus
        authorizationStatus = status
        isLocationEnabled = Self.isAuthorized(status)

        let shouldEnableBackground =
            wantsBackgroundUpdates
            && status == .authorizedAlways
            && Self.hasLocationBackgroundMode

        let wasRunning = isUpdating
        if wasRunning {
            manager.stopUpdatingLocation()
        }

        manager.allowsBackgroundLocationUpdates = shouldEnableBackground
        manager.showsBackgroundLocationIndicator = shouldEnableBackground

        if wasRunning && restartIfNeeded && isLocationEnabled {
            manager.startUpdatingLocation()
        }
    }

    private func ensureBackgroundActivitySession() {
        guard wantsBackgroundUpdates, hasAlwaysAuthorization, Self.hasLocationBackgroundMode else {
            endBackgroundActivitySession()
            return
        }
        guard backgroundActivitySession == nil else { return }
        backgroundActivitySession = CLBackgroundActivitySession()
        AppLogger.location.notice("CLBackgroundActivitySession started for ride recording")
    }

    private func endBackgroundActivitySession() {
        backgroundActivitySession?.invalidate()
        backgroundActivitySession = nil
    }

    private static var hasLocationBackgroundMode: Bool {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        return modes?.contains("location") == true
    }

    private static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedAlways || status == .authorizedWhenInUse
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Prefer sync delivery on the main run loop so background wake-ups are not deferred.
        let run = {
            MainActor.assumeIsolated {
                let status = manager.authorizationStatus
                AppLogger.location.notice("Authorization changed → \(String(describing: status))")
                // Do not call requestAlwaysAuthorization() from this delegate — re-entrancy
                // here (especially after "Allow Once") can terminate the app on launch.
                self.applyBackgroundConfiguration(restartIfNeeded: true)
                if self.wantsBackgroundUpdates {
                    self.ensureBackgroundActivitySession()
                }
                self.startIfAuthorized()
            }
        }
        if Thread.isMainThread {
            run()
        } else {
            DispatchQueue.main.sync(execute: run)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let run = {
            MainActor.assumeIsolated {
                self.deliverLocationUpdate(location)
            }
        }
        if Thread.isMainThread {
            run()
        } else {
            // Keep background wake-ups ordered; async Task can be delayed until unlock.
            DispatchQueue.main.sync(execute: run)
        }
    }

    private func deliverLocationUpdate(_ location: CLLocation) {
        guard isUpdating else { return }
        lastLocation = location
        updateTick &+= 1
        if LogThrottle.shouldLog(key: "location.update", interval: 30) {
            let speedKmh = location.speed >= 0 ? location.speed * 3.6 : -1
            AppLogger.location.debug(
                "Fix @ \(AppLogger.coordinate(location.coordinate.latitude, location.coordinate.longitude), privacy: .public) acc=\(location.horizontalAccuracy, format: .fixed(precision: 1))m spd=\(speedKmh, format: .fixed(precision: 0))km/h"
            )
        }
        onLocationUpdate?(location)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let run = {
            MainActor.assumeIsolated {
                AppLogger.location.error("Location error: \(error.localizedDescription, privacy: .public)")
            }
        }
        if Thread.isMainThread {
            run()
        } else {
            DispatchQueue.main.async(execute: run)
        }
    }
}
