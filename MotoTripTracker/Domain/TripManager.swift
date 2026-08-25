import CoreLocation
import Foundation

/// Live ride orchestrator — mirrors Android `TripManager`.
@Observable
@MainActor
final class TripManager {
    private(set) var sessionState = RideSessionState()

    private let speedFilter = SpeedFilter()
    private let stopDetector = StopDetector()
    private let gForceTracker: GForceTracker
    private let repository: TripRepository

    private var currentTripID: UUID?
    private var lastLocation: CLLocation?
    private var isTracking = false
    private var isPaused = false
    private var elevationSmoother = ElevationSmoother()
    private var sessionMaxSpeedKmh = 0
    private let speedSmoother = SpeedSmoother()

    init(repository: TripRepository, gForceTracker: GForceTracker? = nil) {
        self.repository = repository
        self.gForceTracker = gForceTracker ?? GForceTracker()
    }

    func startTrip() {
        isTracking = true
        isPaused = false
        lastLocation = nil
        sessionMaxSpeedKmh = 0
        stopDetector.reset()
        elevationSmoother = ElevationSmoother()
        gForceTracker.startTracking(resetSession: true)

        let startTime = Date().timeIntervalSince1970
        var stats = TripStats(tripStartTime: startTime)
        sessionState = RideSessionState(stats: stats, isActive: true, isPaused: false)
        currentTripID = repository.startNewTrip(startTime: startTime)
    }

    func pauseTrip() {
        guard isTracking, !isPaused else { return }
        isPaused = true
        gForceTracker.stopTracking()
        stopDetector.reset()
        lastLocation = nil

        var stats = sessionState.stats
        stats.speed = 0
        stats.currentGForce = 0
        sessionState = RideSessionState(stats: stats, isActive: true, isPaused: true)
    }

    func resumeTrip() {
        guard isTracking, isPaused else { return }
        isPaused = false
        stopDetector.reset()
        lastLocation = nil
        gForceTracker.startTracking(resetSession: false)
        sessionState = RideSessionState(stats: sessionState.stats, isActive: true, isPaused: false)
    }

    func onLocationUpdate(_ location: CLLocation) {
        guard isTracking, !isPaused else { return }
        guard speedFilter.isValid(location) else { return }

        let currentSpeedMps = speedFilter.processedSpeed(from: location)
        let currentSpeedKmh = currentSpeedMps * 3.6
        let currentTime = location.timestamp.timeIntervalSince1970

        let rawSpeedKmh = Int(max(0, location.speed) * 3.6)
        if rawSpeedKmh > sessionMaxSpeedKmh {
            sessionMaxSpeedKmh = rawSpeedKmh
        }

        var elevationDelta = 0.0
        var distanceDelta = 0.0

        if let prev = lastLocation {
            if location.verticalAccuracy >= 0 {
                elevationDelta = elevationSmoother.calculateGain(rawAltitude: location.altitude)
            }
            if currentSpeedMps > 0.1 {
                distanceDelta = prev.distance(from: location)
            }
        }

        var stats = sessionState.stats
        var newMoving = stats.movingTime
        var newStopped = stats.stoppedTime

        stopDetector.updateTimes(currentTime: currentTime) { movingDeltaMs, stoppedDeltaMs in
            newMoving += movingDeltaMs / 1000
            newStopped += stoppedDeltaMs / 1000
            self.speedSmoother.reset()
        }

        let movingHours = Double(newMoving) / 3600
        let totalKm = (stats.distanceMeters + distanceDelta) / 1000
        let newAvgSpeed = movingHours > 0 ? totalKm / movingHours : 0

        stats.speed = currentSpeedKmh
        stats.movingTime = newMoving
        stats.stoppedTime = newStopped
        stats.distanceMeters += distanceDelta
        stats.maxSpeed = max(stats.maxSpeed, Double(sessionMaxSpeedKmh))
        stats.avgSpeed = newAvgSpeed
        stats.totalElevationGain += elevationDelta
        stats.currentGForce = gForceTracker.currentGForce
        stats.maxGForce = max(stats.maxGForce, gForceTracker.maxSessionGForce)

        lastLocation = location
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
    }

    func stopTrip() {
        guard isTracking else { return }
        isTracking = false
        isPaused = false
        speedSmoother.reset()
        gForceTracker.stopTracking()

        let endTime = Date().timeIntervalSince1970
        var stats = sessionState.stats
        var finalMoving = stats.movingTime
        var finalStopped = stats.stoppedTime

        stopDetector.updateTimes(currentTime: endTime) { movingDeltaMs, stoppedDeltaMs in
            finalMoving += movingDeltaMs / 1000
            finalStopped += stoppedDeltaMs / 1000
        }

        let movingHours = Double(finalMoving) / 3600
        let totalKm = stats.distanceMeters / 1000
        stats.speed = 0
        stats.currentGForce = 0
        stats.movingTime = finalMoving
        stats.stoppedTime = finalStopped
        stats.avgSpeed = movingHours > 0 ? totalKm / movingHours : 0

        if let tripID = currentTripID {
            repository.saveTrip(tripID: tripID, finalStats: stats, endTime: endTime)
        }

        stopDetector.reset()
        currentTripID = nil
        sessionState = RideSessionState(stats: stats, isActive: false, isPaused: false)
    }
}
