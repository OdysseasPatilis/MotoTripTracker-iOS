import Foundation
import Testing
@testable import MotoTripTracker

struct RideProfileSeriesTests {
    @Test func elevationProfileStartsAtTheLowestPoint() {
        let points = [
            sample(altitude: 100, speed: 5, time: 0),
            sample(altitude: 140, speed: 8, time: 10),
            sample(altitude: 110, speed: 6, time: 20)
        ]
        let series = RideProfileSeries.make(points: points, layer: .elevation)
        #expect(series.count == 3)
        #expect(series.map(\.value).min() == 0)
        #expect((series.map(\.value).max() ?? 0) > 30)
        #expect((series.map(\.value).max() ?? 0) < 50)
    }

    @Test func speedProfileKeepsTheEndsAndSmoothsASpike() {
        var points: [RoutePoint] = []
        for index in 0..<12 {
            let spike = index == 6 ? 40.0 : 10.0
            points.append(sample(altitude: 10, speed: spike, time: TimeInterval(index)))
        }
        let series = RideProfileSeries.make(points: points, layer: .speed)
        #expect(series.first?.fraction == 0)
        #expect(abs((series.last?.fraction ?? 0) - 1) < 0.001)
        let peak = RideProfileSeries.peak(in: series)?.value ?? 0
        #expect(peak < 40 * 3.6)
        #expect(peak > 10 * 3.6)
    }

    @Test func axisCeilingLandsOnARoundStep() {
        #expect(RideProfileAxis.niceCeiling(0) == 1)
        #expect(RideProfileAxis.niceCeiling(5) == 5)
        #expect(RideProfileAxis.niceCeiling(23) == 50)
        #expect(RideProfileAxis.niceCeiling(87) == 100)
        #expect(RideProfileAxis.niceCeiling(100) == 100)
    }

    @Test func speedShadeRunsFromLightToDark() {
        #expect(RideProfileAxis.speedShade(value: 0, minimum: 0, maximum: 80) == 0)
        #expect(RideProfileAxis.speedShade(value: 40, minimum: 0, maximum: 80) == 0.5)
        #expect(RideProfileAxis.speedShade(value: 80, minimum: 0, maximum: 80) == 1)
        #expect(RideProfileAxis.speedShade(value: 30, minimum: 30, maximum: 30) == 0.5)
    }

    @Test func playheadReadsTheValueAlongTheCurve() {
        let samples = [
            RideProfileSample(fraction: 0, value: 0),
            RideProfileSample(fraction: 1, value: 100)
        ]
        #expect(RideProfileSeries.value(at: 0.25, in: samples) == 25)
    }

    private func sample(altitude: Double, speed: Double, time: TimeInterval) -> RoutePoint {
        RoutePoint(
            latitude: 37.98,
            longitude: 23.72,
            altitude: altitude,
            speedMps: speed,
            timestamp: time
        )
    }
}
