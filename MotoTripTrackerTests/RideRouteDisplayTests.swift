import Foundation
import Testing
@testable import MotoTripTracker

struct RideRouteDisplayTests {
    @Test func prefersStoredPointsWhenAtLeastTwoExist() {
        let trip = Trip(
            startTime: 1_700_000_000,
            endTime: 1_700_000_100,
            encodedRoutePolyline: PolylineEncoder.encode([
                (lat: 38.0, lng: 24.0),
                (lat: 38.1, lng: 24.1)
            ])
        )
        let stored = [
            RoutePoint(latitude: 37.98, longitude: 23.72, altitude: 10, speedMps: 12, timestamp: 1_700_000_000),
            RoutePoint(latitude: 37.99, longitude: 23.73, altitude: 12, speedMps: 14, timestamp: 1_700_000_010)
        ]

        let display = RideRouteDisplay.resolve(trip: trip, storedPoints: stored)

        #expect(!display.usingPolylineFallback)
        #expect(display.points.count == 2)
        #expect(display.points[0].latitude == 37.98)
        #expect(display.waypoints.isEmpty)
    }

    @Test func rebuildsFromEncodedPolylineWhenStoredPointsAreMissing() {
        let coords = [(lat: 37.98, lng: 23.72), (lat: 37.99, lng: 23.73), (lat: 38.00, lng: 23.74)]
        let trip = Trip(
            startTime: 1_700_000_000,
            endTime: 1_700_000_090,
            encodedRoutePolyline: PolylineEncoder.encode(coords)
        )

        let display = RideRouteDisplay.resolve(trip: trip, storedPoints: [])

        #expect(display.usingPolylineFallback)
        #expect(display.points.count == 3)
        #expect(abs(display.points[0].latitude - 37.98) < 0.0001)
        #expect(display.waypoints.isEmpty)
        #expect(display.coordinates.count == 3)
    }

    @Test func isEmptyWhenTripAndPointsAreMissing() {
        let display = RideRouteDisplay.resolve(trip: nil, storedPoints: [])
        #expect(!display.usingPolylineFallback)
        #expect(display.points.isEmpty)
        #expect(display.coordinates.isEmpty)
    }
}
