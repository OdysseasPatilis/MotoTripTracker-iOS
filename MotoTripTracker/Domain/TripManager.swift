import CoreLocation
import Foundation
import os

/// Live ride orchestrator — mirrors Android `TripManager`.
@Observable
@MainActor
final class TripManager {
    private(set) var sessionState = RideSessionState()

    /// Ordered coordinates for the current session, used to draw the live trail on the dashboard map.
    private(set) var routeCoordinates: [CLLocationCoordinate2D] = []

    private let speedFilter = SpeedFilter()
    private let stopDetector = StopDetector()
    private let gForceTracker: GForceTracker
    private let repository: TripRepository
    private let cornerDetector = CornerDetector()

    private var currentTripID: UUID?
    private var lastLocation: CLLocation?
    private var isTracking = false
    private var isPaused = false
    private var elevationSmoother = ElevationSmoother()
    private var sessionMaxSpeedKmh = 0.0
    private let speedSmoother = SpeedSmoother()

    private static let movingSpeedMps = 0.1
    private static let maxPlausibleSpeedKmh = 300.0
    private static let maxStepMeters: CLLocationDistance = 80
    static let minSaveDistanceMeters: Double = 50

    init(repository: TripRepository, gForceTracker: GForceTracker? = nil) {
        self.repository = repository
        self.gForceTracker = gForceTracker ?? GForceTracker()
    }

    func startTrip() {
        isTracking = true
        isPaused = false
        lastLocation = nil
        routeCoordinates = []
        sessionMaxSpeedKmh = 0
        stopDetector.reset()
        speedSmoother.reset()
        cornerDetector.reset()
        elevationSmoother = ElevationSmoother()
        gForceTracker.startTracking(resetSession: true)

        let startTime = Date().timeIntervalSince1970
        let stats = TripStats(tripStartTime: startTime)
        sessionState = RideSessionState(stats: stats, isActive: true, isPaused: false)
        currentTripID = repository.startNewTrip(startTime: startTime)
        LogThrottle.reset(key: "trip.location")
        AppLogger.trip.notice("Trip started id=\(AppLogger.uuidShort(self.currentTripID ?? UUID()), privacy: .public)")
    }

    func pauseTrip() {
        guard isTracking, !isPaused else {
            AppLogger.trip.debug("Pause ignored — tracking=\(self.isTracking) paused=\(self.isPaused)")
            return
        }
        isPaused = true
        gForceTracker.stopTracking()
        stopDetector.reset()
        speedSmoother.reset()
        lastLocation = nil

        var stats = sessionState.stats
        stats.speed = 0
        stats.currentGForce = 0
        stats.currentLateralGForce = 0
        sessionState = RideSessionState(stats: stats, isActive: true, isPaused: true)
        AppLogger.trip.notice("Trip paused \(AppLogger.tripSummary(stats), privacy: .public)")
    }

    func resumeTrip() {
        guard isTracking, isPaused else {
            AppLogger.trip.debug("Resume ignored — tracking=\(self.isTracking) paused=\(self.isPaused)")
            return
        }
        isPaused = false
        stopDetector.reset()
        speedSmoother.reset()
        lastLocation = nil
        gForceTracker.startTracking(resetSession: false)
        sessionState = RideSessionState(stats: sessionState.stats, isActive: true, isPaused: false)
        AppLogger.trip.notice("Trip resumed \(AppLogger.tripSummary(self.sessionState.stats), privacy: .public)")
    }

    func onLocationUpdate(_ location: CLLocation) {
        guard isTracking, !isPaused else { return }

        let accuracy = location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil
        let gpsQuality = GpsQuality.fromAccuracyMeters(accuracy)

        guard speedFilter.isValid(location) else {
            var rejected = sessionState.stats
            rejected.gpsAccuracyMeters = accuracy
            rejected.gpsQuality = gpsQuality
            sessionState = RideSessionState(stats: rejected, isActive: true, isPaused: false)
            if LogThrottle.shouldLog(key: "trip.invalidGPS", interval: 15) {
                AppLogger.trip.debug(
                    "GPS rejected accuracy=\(location.horizontalAccuracy, format: .fixed(precision: 1))m speed=\(location.speed, format: .fixed(precision: 2))m/s"
                )
            }
            return
        }

        let currentSpeedMps = speedFilter.processedSpeed(from: location)
        let currentTime = location.timestamp.timeIntervalSince1970
        let isMoving = currentSpeedMps > Self.movingSpeedMps

        let displaySpeedKmh: Double
        if isMoving {
            displaySpeedKmh = speedSmoother.smoothedSpeedKmh(fromSpeedMps: currentSpeedMps)
        } else {
            speedSmoother.reset()
            displaySpeedKmh = 0
        }

        if isMoving, displaySpeedKmh >= 0, displaySpeedKmh <= Self.maxPlausibleSpeedKmh {
            sessionMaxSpeedKmh = max(sessionMaxSpeedKmh, displaySpeedKmh)
        }

        if isMoving {
            cornerDetector.onLocation(location, speedMps: currentSpeedMps)
        }

        var elevationDelta = 0.0
        var distanceDelta = 0.0

        if let prev = lastLocation {
            if location.verticalAccuracy >= 0 {
                elevationDelta = elevationSmoother.calculateGain(rawAltitude: location.altitude)
            }
            if isMoving {
                let step = prev.distance(from: location)
                if step >= 0, step <= Self.maxStepMeters {
                    distanceDelta = step
                } else if step > Self.maxStepMeters {
                    AppLogger.trip.warning(
                        "Rejected GPS teleport step=\(step, format: .fixed(precision: 1))m (max \(Self.maxStepMeters)m)"
                    )
                }
            }
        }

        var stats = sessionState.stats
        var newMoving = stats.movingTime
        var newStopped = stats.stoppedTime

        stopDetector.updateTimes(currentTime: currentTime, isMoving: isMoving) { movingDeltaMs, stoppedDeltaMs in
            newMoving += movingDeltaMs / 1000
            newStopped += stoppedDeltaMs / 1000
        }

        gForceTracker.update(speedMps: currentSpeedMps, timestamp: currentTime)

        let movingHours = Double(newMoving) / 3600
        let totalKm = (stats.distanceMeters + distanceDelta) / 1000
        let newAvgSpeed = movingHours > 0 ? totalKm / movingHours : 0
        let lateralCurrent = cornerDetector.lastEstimatedLateralG
        let maxLateral = max(stats.maxLateralGForce, cornerDetector.maxEstimatedLateralG)

        stats.speed = displaySpeedKmh
        stats.movingTime = newMoving
        stats.stoppedTime = newStopped
        stats.distanceMeters += distanceDelta
        stats.maxSpeed = max(stats.maxSpeed, sessionMaxSpeedKmh)
        stats.avgSpeed = newAvgSpeed
        stats.totalElevationGain += elevationDelta
        stats.currentGForce = gForceTracker.currentGForce
        stats.maxGForce = max(stats.maxGForce, gForceTracker.maxSessionGForce)
        stats.currentLateralGForce = lateralCurrent
        stats.maxLateralGForce = maxLateral
        stats.cornerCount = cornerDetector.cornerCount
        stats.gpsAccuracyMeters = accuracy
        stats.gpsQuality = gpsQuality

        lastLocation = location
        routeCoordinates.append(location.coordinate)
        sessionState = RideSessionState(stats: stats, isActive: true, isPaused: false)

        guard let tripID = currentTripID else { return }
        repository.addRoutePointAndUpdateStats(
            tripID: tripID,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude,
            speedMps: currentSpeedMps,
            time: currentTime,
            runningStats: stats
        )

        if LogThrottle.shouldLog(key: "trip.location", interval: 30) {
            AppLogger.trip.info(
                "Tick @ \(AppLogger.coordinate(location.coordinate.latitude, location.coordinate.longitude), privacy: .public) — \(AppLogger.tripSummary(stats), privacy: .public)"
            )
        }
    }

    /// Stops the ride. Returns `false` when the ride was discarded for being too short.
    @discardableResult
    func stopTrip(minDistanceMeters: Double = TripManager.minSaveDistanceMeters) -> Bool {
        guard isTracking else {
            AppLogger.trip.debug("Stop ignored — not tracking")
            return false
        }
        isTracking = false
        isPaused = false
        speedSmoother.reset()
        gForceTracker.stopTracking()

        let endTime = Date().timeIntervalSince1970
        var stats = sessionState.stats
        var finalMoving = stats.movingTime
        var finalStopped = stats.stoppedTime

        stopDetector.updateTimes(currentTime: endTime, isMoving: false) { movingDeltaMs, stoppedDeltaMs in
            finalMoving += movingDeltaMs / 1000
            finalStopped += stoppedDeltaMs / 1000
        }

        let movingHours = Double(finalMoving) / 3600
        let totalKm = stats.distanceMeters / 1000
        stats.speed = 0
        stats.currentGForce = 0
        stats.currentLateralGForce = 0
        stats.movingTime = finalMoving
        stats.stoppedTime = finalStopped
        stats.avgSpeed = movingHours > 0 ? totalKm / movingHours : 0
        stats.cornerCount = cornerDetector.cornerCount
        stats.maxLateralGForce = max(stats.maxLateralGForce, cornerDetector.maxEstimatedLateralG)

        let tripID = currentTripID
        let saved: Bool
        if let tripID {
            if stats.distanceMeters < minDistanceMeters {
                repository.deleteTrip(id: tripID)
                AppLogger.trip.notice(
                    "Trip discarded id=\(AppLogger.uuidShort(tripID), privacy: .public) dist=\(stats.distanceMeters, format: .fixed(precision: 1))m < \(minDistanceMeters, format: .fixed(precision: 0))m"
                )
                saved = false
            } else {
                repository.saveTrip(tripID: tripID, finalStats: stats, endTime: endTime)
                AppLogger.trip.notice(
                    "Trip stopped id=\(AppLogger.uuidShort(tripID), privacy: .public) — \(AppLogger.tripSummary(stats), privacy: .public)"
                )
                saved = true
            }
        } else {
            saved = false
        }

        stopDetector.reset()
        cornerDetector.reset()
        currentTripID = nil
        sessionState = RideSessionState(stats: stats, isActive: false, isPaused: false)
        LogThrottle.reset(key: "trip.location")
        return saved
    }
}
