import CoreGraphics
import Testing
@testable import MotoTripTracker

struct RideRouteSparklineTests {
    @Test func sparklineKeepsNorthUpAndInsideTheThumbnail() {
        let encoded = PolylineEncoder.encode([
            (lat: 37.98, lng: 23.72),
            (lat: 37.99, lng: 23.72)
        ])
        let points = RideRouteSparklinePath.normalizedPoints(encoded: encoded)
        #expect(points.count == 2)
        #expect(points.allSatisfy { $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 })
        #expect(points[1].y < points[0].y)
    }

    @Test func sparklineSamplesLongRoutesAndKeepsTheEnds() {
        let coordinates = (0..<40).map { index in
            (lat: 37.98 + Double(index) * 0.001, lng: 23.72)
        }
        let sampled = RideRouteSparklinePath.sample(coordinates, limit: RideRouteSparklinePath.maxPoints)
        #expect(sampled.count == RideRouteSparklinePath.maxPoints)
        #expect(sampled.first?.lat == coordinates.first?.lat)
        #expect(sampled.last?.lat == coordinates.last?.lat)
    }

    @Test func sparklineIsEmptyWithoutAPolyline() {
        #expect(RideRouteSparklinePath.normalizedPoints(encoded: nil).isEmpty)
        #expect(RideRouteSparklinePath.normalizedPoints(encoded: "").isEmpty)
    }
}
