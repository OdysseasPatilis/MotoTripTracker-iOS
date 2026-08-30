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

    @Test func athensRegionPackDecodesAndLooksUpCells() throws {
        let json = """
        {
          "id": "athens",
          "name": "Greater Athens",
          "version": 1,
          "gridScale": 500.0,
          "bbox": {"south": 37.82, "west": 23.55, "north": 38.15, "east": 23.95},
          "cells": {"18991_11863": 50, "18992_11863": 70}
        }
        """.data(using: .utf8)!
        let pack = try SpeedLimitRegionPackStore.decode(json)

        let inside = CLLocation(latitude: 37.9838, longitude: 23.7275)
        let outside = CLLocation(latitude: 40.64, longitude: 22.94) // Thessaloniki
        #expect(pack.contains(inside))
        #expect(!pack.contains(outside))

        // 37.9838*500 ≈ 18991.9 → trunc 18991; 23.7275*500 ≈ 11863.75 → trunc 11863
        #expect(pack.limit(for: inside) == 50)
        #expect(SpeedLimitRegionPackStore.isInsideBundledRegion(inside, packs: [pack]))
        #expect(!SpeedLimitRegionPackStore.isInsideBundledRegion(outside, packs: [pack]))
    }

    @Test func bundledAthensPackIsAvailable() {
        let packs = SpeedLimitRegionPackStore.bundled
        #expect(!packs.isEmpty)
        let athens = packs.first { $0.id == "athens" }
        #expect(athens != nil)
        #expect((athens?.cells.count ?? 0) > 1000)
        let downtown = CLLocation(latitude: 37.9838, longitude: 23.7275)
        #expect(athens?.contains(downtown) == true)
    }

    @Test func rideMomentsTellStoriesNotDuplicateStats() {
        let start: TimeInterval = 1_700_000_000
        var points: [RoutePoint] = []
        // Climbing + accelerating stretch
        for i in 0..<40 {
            let t = start + Double(i) * 2
            points.append(
                RoutePoint(
                    latitude: 37.98 + Double(i) * 0.0002,
                    longitude: 23.72,
                    altitude: 100 + Double(i) * 2.5,
                    speedMps: 5 + Double(i) * 0.6,
                    timestamp: t
                )
            )
        }
        // Stop for 40s
        let stopStart = start + 80
        for i in 0..<20 {
            points.append(
                RoutePoint(
                    latitude: 37.988,
                    longitude: 23.72,
                    altitude: 200,
                    speedMps: 0.1,
                    timestamp: stopStart + Double(i) * 2
                )
            )
        }
        // Descent
        for i in 0..<25 {
            points.append(
                RoutePoint(
                    latitude: 37.99 + Double(i) * 0.0002,
                    longitude: 23.72,
                    altitude: 200 - Double(i) * 3,
                    speedMps: 15,
                    timestamp: stopStart + 40 + Double(i) * 2
                )
            )
        }

        let trip = Trip(
            startTime: start,
            distanceMeters: 12_000,
            movingTime: 600,
            stoppedTime: 40,
            maxSpeed: 120,
            maxGForce: 0.4,
            elevationGain: 100,
            avgSpeed: 55,
            maxLateralGForce: 0.3,
            cornerCount: 14
        )

        let result = RideMomentsCalculator.calculate(trip: trip, points: points)
        let moments = result.moments
        let ids = Set(moments.map(\.id))

        #expect(!moments.isEmpty)
        let hasStory = ids.contains("peak-speed")
            || ids.contains("biggest-climb")
            || ids.contains("longest-stop")
        #expect(hasStory)

        let duplicateTitles = Set(["Max G", "Corners", "Moving pace"])
        #expect(moments.allSatisfy { !duplicateTitles.contains($0.title) })
        #expect(moments.allSatisfy { !$0.systemImage.isEmpty })
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

    @Test func openingHoursDetectsOpenAndClosed() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // Wednesday 2026-08-26 12:00 UTC
        let components = DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 8, day: 26, hour: 12)
        let noon = components.date!

        #expect(OpeningHoursEvaluator.status(of: "24/7", at: noon, calendar: calendar) == .open)
        #expect(OpeningHoursEvaluator.status(of: "Mo-Su 06:00-22:00", at: noon, calendar: calendar) == .open)
        #expect(OpeningHoursEvaluator.status(of: "Mo-Su 18:00-22:00", at: noon, calendar: calendar) == .closed)
        #expect(OpeningHoursEvaluator.status(of: nil, at: noon, calendar: calendar) == .unknown)
        #expect(OpeningHoursEvaluator.status(of: "complex || unsupported", at: noon, calendar: calendar) == .unknown)
        #expect(OpeningHoursEvaluator.shortLabel(of: "24/7") == "24/7")
        #expect(OpeningHoursEvaluator.shortLabel(of: "Mo-Su 06:00-22:00") == "06:00–22:00")
    }

    @Test func twistinessScoreCombinesCornersAndLateralG() {
        let straight = TwistinessCalculator.score(cornerCount: 2, distanceKm: 20, maxLateralGForce: 0.2)
        let twisty = TwistinessCalculator.score(cornerCount: 40, distanceKm: 20, maxLateralGForce: 0.7)
        #expect(straight < twisty)
        #expect(TwistinessCalculator.rating(for: twisty) == .twisty || TwistinessCalculator.rating(for: twisty) == .epic)
    }

    @Test func routeReplayEngineInterpolatesBetweenPoints() {
        let points = [
            RoutePoint(latitude: 37.98, longitude: 23.72, altitude: 100, speedMps: 10, timestamp: 1_000),
            RoutePoint(latitude: 37.99, longitude: 23.73, altitude: 110, speedMps: 20, timestamp: 1_100)
        ]
        let engine = RouteReplayEngine(points: points)
        #expect(engine.duration == 100)
        let mid = engine.frame(at: 50)
        #expect(mid != nil)
        #expect((mid?.speedKmh ?? 0) > 30)
        #expect((mid?.speedKmh ?? 0) < 90)
    }

    @Test func openMeteoHourlyTimeParsesLocalFormat() {
        let tz = TimeZone(identifier: "Europe/Athens")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let components = DateComponents(year: 2026, month: 8, day: 29, hour: 3)
        let expected = calendar.date(from: components)!

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.timeZone = tz
        let parsed = formatter.date(from: "2026-08-29T03:00")

        #expect(parsed != nil)
        #expect(abs((parsed ?? .distantPast).timeIntervalSince(expected)) < 1)
    }

    @Test func rideDistanceFilterClampsGpsJitter() {
        // 1 Hz fix at 100 km/h ≈ 27.8 m; 80 m wander must not count as 288 km/h.
        let clamped = RideDistanceFilter.distanceDelta(
            geographicMeters: 80,
            speedMps: 100 / 3.6,
            timeDelta: 1
        )
        #expect(clamped < 45)
        #expect(clamped > 20)

        let highwayGap = RideDistanceFilter.distanceDelta(
            geographicMeters: 320,
            speedMps: 110 / 3.6,
            timeDelta: 10
        )
        #expect(highwayGap > 250)
        #expect(highwayGap <= 320)
    }

    @Test func averageSpeedCannotExceedMax() {
        let avg = RideDistanceFilter.averageSpeedKmh(
            distanceMeters: 46_000,
            movingTimeSeconds: 8 * 60,
            maxSpeedKmh: 103.3
        )
        #expect(avg <= 103.3)
        #expect(avg > 0)
    }

    @Test func petrolSearchStrategyAdaptsRadiusForDensity() {
        let origin = CLLocationCoordinate2D(latitude: 37.98, longitude: 23.72)

        let urban = PetrolSearchStrategy.plan(
            origin: origin,
            speedKmh: 30,
            isNearMotorway: false,
            stationCountsByRadius: [2_000: 6, 5_000: 10, 10_000: 15, 20_000: 20, 50_000: 25]
        )
        #expect(urban.context == .urban)
        #expect(urban.activeRadiusMeters == 2_000)

        let town = PetrolSearchStrategy.plan(
            origin: origin,
            speedKmh: 40,
            isNearMotorway: false,
            stationCountsByRadius: [2_000: 1, 5_000: 2, 10_000: 4, 20_000: 6, 50_000: 8]
        )
        #expect(town.context == .town)
        #expect(town.activeRadiusMeters == 5_000)

        let rural = PetrolSearchStrategy.plan(
            origin: origin,
            speedKmh: 50,
            isNearMotorway: false,
            stationCountsByRadius: [2_000: 0, 5_000: 0, 10_000: 0, 20_000: 1, 50_000: 2]
        )
        #expect(rural.context == .rural)
        #expect(rural.activeRadiusMeters == 20_000)

        let highway = PetrolSearchStrategy.plan(
            origin: origin,
            speedKmh: 110,
            isNearMotorway: true,
            stationCountsByRadius: [2_000: 0, 10_000: 1, 20_000: 2, 50_000: 3]
        )
        #expect(highway.context == .highway)
        #expect(highway.prioritizeHighway)
        #expect(highway.activeRadiusMeters == 10_000)
    }
}
