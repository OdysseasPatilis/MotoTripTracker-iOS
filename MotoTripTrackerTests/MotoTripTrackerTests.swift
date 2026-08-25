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

    @Test func stopDetectorCountsShortGapsAsMoving() {
        let detector = StopDetector()
        var moving: Int64 = 0
        var stopped: Int64 = 0
        let base: TimeInterval = 1_000_000
        detector.updateTimes(currentTime: base) { _, _ in }
        detector.updateTimes(currentTime: base + 2) { m, s in
            moving += m
            stopped += s
        }
        #expect(moving == 2000)
        #expect(stopped == 0)
    }

    @Test func stopDetectorSplitsLongerGaps() {
        let detector = StopDetector()
        var moving: Int64 = 0
        var stopped: Int64 = 0
        let base: TimeInterval = 1_000_000
        detector.updateTimes(currentTime: base) { _, _ in }
        detector.updateTimes(currentTime: base + 10) { m, s in
            moving += m
            stopped += s
        }
        #expect(moving == 2000)
        #expect(stopped == 8000)
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
}
