import CoreLocation
import Foundation
import Testing
@testable import MotoTripTracker

struct MotoTripTrackerTests {

    @Test func speedFilterRejectsInaccurateLocations() {
        let filter = SpeedFilter()
        let bad = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.98, longitude: 23.72),
            altitude: 100,
            horizontalAccuracy: 40,
            verticalAccuracy: 10,
            timestamp: Date()
        )
        let good = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.98, longitude: 23.72),
            altitude: 100,
            horizontalAccuracy: 8,
            verticalAccuracy: 10,
            course: 0,
            speed: 10,
            timestamp: Date()
        )
        #expect(!filter.isValid(bad))
        #expect(filter.isValid(good))
    }

    @Test func speedFilterKillsGhostDrift() {
        let filter = SpeedFilter()
        let drifting = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.98, longitude: 23.72),
            altitude: 100,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 0,
            speed: 0.4,
            timestamp: Date()
        )
        #expect(filter.processedSpeed(from: drifting) == 0)
    }

    @Test func stopDetectorCountsMovingWhenSpeedAboveThreshold() {
        let detector = StopDetector()
        var moving: Int64 = 0
        var stopped: Int64 = 0
        let base: TimeInterval = 1_000_000
        detector.updateTimes(currentTime: base, isMoving: true) { _, _ in }
        detector.updateTimes(currentTime: base + 2, isMoving: true) { m, s in
            moving += m
            stopped += s
        }
        #expect(moving == 2000)
        #expect(stopped == 0)
    }

    @Test func stopDetectorCountsStoppedWhenNotMoving() {
        let detector = StopDetector()
        var moving: Int64 = 0
        var stopped: Int64 = 0
        let base: TimeInterval = 1_000_000
        detector.updateTimes(currentTime: base, isMoving: true) { _, _ in }
        detector.updateTimes(currentTime: base + 5, isMoving: false) { m, s in
            moving += m
            stopped += s
        }
        #expect(moving == 0)
        #expect(stopped == 5000)
    }

    @Test func gForceTrackerUsesSpeedDeltasAndClampsPeaks() async {
        let tracker = await MainActor.run { GForceTracker() }
        await MainActor.run {
            tracker.startTracking(resetSession: true)
            tracker.update(speedMps: 10, timestamp: 1_000)
            tracker.update(speedMps: 20, timestamp: 1_001) // 1.02 g raw
            tracker.update(speedMps: 50, timestamp: 1_002) // huge spike → clamped
        }
        let maxG = await MainActor.run { tracker.maxSessionGForce }
        let current = await MainActor.run { tracker.currentGForce }
        #expect(maxG <= 1.2)
        #expect(current <= 1.2)
        #expect(maxG > 0)
    }

    @Test func elevationSmootherIgnoresNoise() {
        let smoother = ElevationSmoother()
        #expect(smoother.calculateGain(rawAltitude: 100) == 0)
        #expect(smoother.calculateGain(rawAltitude: 101) == 0)

        var totalGain = 0.0
        for altitude in stride(from: 105.0, through: 130.0, by: 5.0) {
            totalGain += smoother.calculateGain(rawAltitude: altitude)
        }
        #expect(totalGain > 2.5)
    }

    @Test func polylineRoundTrip() {
        let original: [(lat: Double, lng: Double)] = [
            (37.9838, 23.7275),
            (37.9845, 23.7280),
            (37.9850, 23.7290)
        ]
        let encoded = PolylineEncoder.encode(original)
        let decoded = PolylineEncoder.decode(encoded)
        #expect(decoded.count == original.count)
        for i in original.indices {
            #expect(abs(decoded[i].lat - original[i].lat) < 0.0001)
            #expect(abs(decoded[i].lng - original[i].lng) < 0.0001)
        }
    }

    @Test func osmMaxSpeedParserHandlesCommonTags() {
        #expect(OSMMaxSpeedParser.parseKmh("50") == 50)
        #expect(OSMMaxSpeedParser.parseKmh("50 km/h") == 50)
        #expect(OSMMaxSpeedParser.parseKmh("GR:urban") == 50)
        #expect(OSMMaxSpeedParser.parseKmh("GR:motorway") == 130)
        #expect(OSMMaxSpeedParser.parseKmh("30 mph") == 48)
        #expect(OSMMaxSpeedParser.parseKmh("signals") == nil)
    }

    @Test func speedSmootherAveragesWindow() {
        let smoother = SpeedSmoother(windowSize: 3)
        _ = smoother.smoothedSpeedKmh(fromSpeedMps: 10 / 3.6)
        _ = smoother.smoothedSpeedKmh(fromSpeedMps: 20 / 3.6)
        let smoothed = smoother.smoothedSpeedKmh(fromSpeedMps: 30 / 3.6)
        #expect(smoothed == 20)
    }

    @Test func cornerDetectorCountsSignificantTurns() {
        let detector = CornerDetector()
        let base = CLLocationCoordinate2D(latitude: 37.98, longitude: 23.72)
        func location(course: Double, latDelta: Double, lonDelta: Double) -> CLLocation {
            CLLocation(
                coordinate: CLLocationCoordinate2D(
                    latitude: base.latitude + latDelta,
                    longitude: base.longitude + lonDelta
                ),
                altitude: 100,
                horizontalAccuracy: 5,
                verticalAccuracy: 5,
                course: course,
                speed: 15,
                timestamp: Date()
            )
        }

        _ = detector.onLocation(location(course: 0, latDelta: 0, lonDelta: 0), speedMps: 15)
        _ = detector.onLocation(location(course: 20, latDelta: 0.0003, lonDelta: 0.0001), speedMps: 15)
        _ = detector.onLocation(location(course: 45, latDelta: 0.0006, lonDelta: 0.0003), speedMps: 15)
        #expect(detector.cornerCount >= 1)
    }

    @Test func gpsQualityBucketsAccuracy() {
        #expect(GpsQuality.fromAccuracyMeters(4) == .excellent)
        #expect(GpsQuality.fromAccuracyMeters(8) == .good)
        #expect(GpsQuality.fromAccuracyMeters(15) == .fair)
        #expect(GpsQuality.fromAccuracyMeters(25) == .poor)
        #expect(GpsQuality.fromAccuracyMeters(nil) == .unknown)
        #expect(GpsQuality.excellent.barCount == 4)
        #expect(GpsQuality.good.barCount == 3)
        #expect(GpsQuality.fair.barCount == 2)
        #expect(GpsQuality.poor.barCount == 1)
    }

    @Test func gpxExporterContainsTrackPoints() {
        let trip = Trip(startTime: 1_700_000_000, title: "Test Ride")
        let points = [
            RoutePoint(latitude: 37.98, longitude: 23.72, altitude: 100, speedMps: 10, timestamp: 1_700_000_000),
            RoutePoint(latitude: 37.981, longitude: 23.721, altitude: 105, speedMps: 12, timestamp: 1_700_000_010)
        ]
        let gpx = GpxExporter.build(trip: trip, points: points)
        #expect(gpx.contains("<trkpt"))
        #expect(gpx.contains("Test Ride"))
        #expect(gpx.contains("37.98"))
    }

    @Test func leaderboardRanksBySpeedDescending() {
        let slow = Trip(startTime: 1, maxSpeed: 100)
        let fast = Trip(startTime: 2, maxSpeed: 150)
        let mid = Trip(startTime: 3, maxSpeed: 120)
        let zero = Trip(startTime: 4, maxSpeed: 0)
        let ranked = LeaderboardRanking.entries(
            from: [slow, fast, mid, zero],
            category: .speed
        )
        #expect(ranked.map(\.trip.maxSpeed) == [150, 120, 100])
        #expect(ranked.map(\.rank) == [1, 2, 3])
    }

    @Test func leaderboardRanksByDistanceAndTurns() {
        let a = Trip(startTime: 1, distanceMeters: 5_000, cornerCount: 3)
        let b = Trip(startTime: 2, distanceMeters: 12_000, cornerCount: 10)
        let distance = LeaderboardRanking.entries(from: [a, b], category: .distance)
        let turns = LeaderboardRanking.entries(from: [a, b], category: .turns)
        #expect(distance.first?.trip.distanceKm == 12)
        #expect(turns.first?.trip.cornerCount == 10)
    }
}
