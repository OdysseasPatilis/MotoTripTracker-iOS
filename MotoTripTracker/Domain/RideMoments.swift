import Foundation

struct RideMoment: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let systemImage: String
}

struct RideMoments: Equatable, Sendable {
    let moments: [RideMoment]
}

/// Builds story-style ride highlights from the route — not a second copy of Stats.
enum RideMomentsCalculator {
    private static let stopSpeedMps = 0.5
    private static let minStopSeconds: Int64 = 20
    private static let minClimbMeters = 12.0
    private static let minDescentMeters = 12.0
    private static let cruiseWindowSeconds: TimeInterval = 45
    private static let minCruiseKmh = 35.0

    static func calculate(trip: Trip, points: [RoutePoint]) -> RideMoments {
        let sorted = points.sorted { $0.timestamp < $1.timestamp }
        guard let start = sorted.first?.timestamp else {
            return RideMoments(moments: ambientMoments(for: trip, points: sorted))
        }

        var moments: [RideMoment] = []

        if let peak = topSpeedHighlight(sorted, rideStart: start) {
            moments.append(peak)
        }
        if let pull = hardestPull(sorted, rideStart: start) {
            moments.append(pull)
        }
        if let climb = peakClimb(sorted, rideStart: start) {
            moments.append(climb)
        }
        if let drop = peakDescent(sorted, rideStart: start) {
            moments.append(drop)
        }
        if let summit = summitHighlight(sorted, rideStart: start) {
            moments.append(summit)
        }
        if let stop = longestStop(sorted, rideStart: start) {
            moments.append(stop)
        }
        if let cruise = sustainedCruise(sorted, rideStart: start) {
            moments.append(cruise)
        }
        if let twisties = twistiesHighlight(trip: trip) {
            moments.append(twisties)
        }
        if let flow = flowHighlight(trip: trip) {
            moments.append(flow)
        }

        moments.append(contentsOf: ambientMoments(for: trip, points: sorted))

        // Prefer unique story moments; keep a short, readable set.
        var seen = Set<String>()
        let unique = moments.filter { seen.insert($0.id).inserted }
        return RideMoments(moments: Array(unique.prefix(6)))
    }

    // MARK: - Story moments from the route

    private static func topSpeedHighlight(_ points: [RoutePoint], rideStart: TimeInterval) -> RideMoment? {
        guard let best = points.max(by: { $0.speedMps < $1.speedMps }), best.speedMps > 1 else { return nil }
        let kmh = Int((best.speedMps * 3.6).rounded())
        let elapsed = max(0, best.timestamp - rideStart)
        let distance = distanceAlongRoute(to: best, in: points)
        return RideMoment(
            id: "peak-speed",
            title: "Peak rush",
            value: "\(kmh) km/h",
            detail: "Hit \(elapsedLabel(elapsed)) in · \(String(format: "%.1f", distance / 1000)) km mark",
            systemImage: "gauge.with.dots.needle.67percent"
        )
    }

    /// Strongest GPS Δv/Δt spike along the route (timed), not just the trip max G number.
    private static func hardestPull(_ points: [RoutePoint], rideStart: TimeInterval) -> RideMoment? {
        guard points.count >= 3 else { return nil }
        var bestG = 0.0
        var bestIndex = 0

        for i in 1..<points.count {
            let dt = points[i].timestamp - points[i - 1].timestamp
            guard dt > 0.2, dt < 5 else { continue }
            let dv = points[i].speedMps - points[i - 1].speedMps
            guard dv > 0 else { continue }
            let g = min(dv / dt / 9.81, 1.2)
            if g > bestG {
                bestG = g
                bestIndex = i
            }
        }

        guard bestG >= 0.25 else { return nil }
        let elapsed = max(0, points[bestIndex].timestamp - rideStart)
        return RideMoment(
            id: "hard-pull",
            title: "Hardest pull",
            value: String(format: "%.2f G", bestG),
            detail: "Strongest acceleration · \(elapsedLabel(elapsed)) in",
            systemImage: "bolt.fill"
        )
    }

    private static func peakClimb(_ points: [RoutePoint], rideStart: TimeInterval) -> RideMoment? {
        guard let segment = bestAltitudeSegment(points, ascending: true), segment.gain >= minClimbMeters else {
            return nil
        }
        let elapsed = max(0, segment.endTime - rideStart)
        return RideMoment(
            id: "biggest-climb",
            title: "Biggest climb",
            value: "+\(Int(segment.gain.rounded())) m",
            detail: "Steepest continuous ascent · ended \(elapsedLabel(elapsed)) in",
            systemImage: "mountain.2.fill"
        )
    }

    private static func peakDescent(_ points: [RoutePoint], rideStart: TimeInterval) -> RideMoment? {
        guard let segment = bestAltitudeSegment(points, ascending: false), segment.gain >= minDescentMeters else {
            return nil
        }
        let elapsed = max(0, segment.endTime - rideStart)
        return RideMoment(
            id: "biggest-drop",
            title: "Biggest drop",
            value: "−\(Int(segment.gain.rounded())) m",
            detail: "Longest downhill stretch · \(elapsedLabel(elapsed)) in",
            systemImage: "arrow.down.right"
        )
    }

    private static func summitHighlight(_ points: [RoutePoint], rideStart: TimeInterval) -> RideMoment? {
        guard let top = points.max(by: { $0.altitude < $1.altitude }) else { return nil }
        let floor = points.map(\.altitude).min() ?? top.altitude
        let rise = top.altitude - floor
        guard rise >= 15 else { return nil }
        let elapsed = max(0, top.timestamp - rideStart)
        return RideMoment(
            id: "summit",
            title: "Summit",
            value: "\(Int(top.altitude.rounded())) m",
            detail: "Highest point · \(elapsedLabel(elapsed)) into the ride",
            systemImage: "flag.fill"
        )
    }

    private static func longestStop(_ points: [RoutePoint], rideStart: TimeInterval) -> RideMoment? {
        guard let stop = longestStopSegment(points), stop.duration >= minStopSeconds else { return nil }
        let elapsed = max(0, stop.startTime - rideStart)
        let when: String
        if elapsed < 90 {
            when = "near the start"
        } else if let last = points.last, stop.startTime > last.timestamp - 120 {
            when = "near the end"
        } else {
            when = "\(elapsedLabel(elapsed)) in"
        }
        return RideMoment(
            id: "longest-stop",
            title: "Longest pause",
            value: RideFormatters.secondsToTime(stop.duration),
            detail: "Stopped \(when)",
            systemImage: "pause.circle.fill"
        )
    }

    /// Best average speed sustained over a rolling time window.
    private static func sustainedCruise(_ points: [RoutePoint], rideStart: TimeInterval) -> RideMoment? {
        guard points.count >= 8 else { return nil }
        var bestAvg = 0.0
        var bestEnd = rideStart
        var left = 0

        for right in 0..<points.count {
            while left < right, points[right].timestamp - points[left].timestamp > cruiseWindowSeconds {
                left += 1
            }
            let span = points[right].timestamp - points[left].timestamp
            guard span >= cruiseWindowSeconds * 0.75 else { continue }

            var sum = 0.0
            let count = Double(right - left + 1)
            for i in left...right { sum += points[i].speedMps }
            let avgKmh = (sum / count) * 3.6
            if avgKmh > bestAvg {
                bestAvg = avgKmh
                bestEnd = points[right].timestamp
            }
        }

        guard bestAvg >= minCruiseKmh else { return nil }
        let elapsed = max(0, bestEnd - rideStart)
        return RideMoment(
            id: "cruise",
            title: "Best cruise",
            value: "\(Int(bestAvg.rounded())) km/h",
            detail: "Fastest ~\(Int(cruiseWindowSeconds))s stretch · \(elapsedLabel(elapsed)) in",
            systemImage: "wind"
        )
    }

    private static func twistiesHighlight(trip: Trip) -> RideMoment? {
        guard trip.cornerCount >= 3, trip.distanceKm >= 1 else { return nil }
        let per10 = Double(trip.cornerCount) / trip.distanceKm * 10
        guard per10 >= 4 else { return nil }
        let vibe: String
        if per10 >= 12 {
            vibe = "Proper twisties"
        } else if per10 >= 8 {
            vibe = "Plenty of bends"
        } else {
            vibe = "Nice flowing turns"
        }
        return RideMoment(
            id: "twisties",
            title: "Twisties",
            value: String(format: "%.0f / 10 km", per10),
            detail: "\(vibe) · \(trip.cornerCount) corners total",
            systemImage: "arrow.triangle.turn.up.right.diamond.fill"
        )
    }

    private static func flowHighlight(trip: Trip) -> RideMoment? {
        let total = trip.totalTime
        guard total >= 300 else { return nil }
        let movingRatio = Double(trip.movingTime) / Double(total)
        if movingRatio >= 0.88 {
            return RideMoment(
                id: "flow",
                title: "Open road",
                value: "\(Int((movingRatio * 100).rounded()))% moving",
                detail: "Barely stopped — a flowing ride",
                systemImage: "road.lanes"
            )
        }
        if movingRatio <= 0.55, trip.stoppedTime >= 120 {
            return RideMoment(
                id: "flow",
                title: "Stop & go",
                value: RideFormatters.secondsToTime(trip.stoppedTime),
                detail: "Lots of pausing — city traffic or sightseeing",
                systemImage: "car.rear.and.tire.marks"
            )
        }
        return nil
    }

    private static func ambientMoments(for trip: Trip, points: [RoutePoint]) -> [RideMoment] {
        let startDate = Date(timeIntervalSince1970: trip.startTime)
        let hour = Calendar.current.component(.hour, from: startDate)
        var items: [RideMoment] = []

        switch hour {
        case 5..<8:
            items.append(
                RideMoment(
                    id: "time-of-day",
                    title: "Dawn ride",
                    value: RideFormatters.timestampToDate(trip.startTime),
                    detail: "Early start — roads are usually quieter",
                    systemImage: "sunrise.fill"
                )
            )
        case 20..<24, 0..<5:
            items.append(
                RideMoment(
                    id: "time-of-day",
                    title: "Night ride",
                    value: RideFormatters.timestampToDate(trip.startTime),
                    detail: "After-dark session",
                    systemImage: "moon.stars.fill"
                )
            )
        default:
            break
        }

        if points.count >= 2, trip.distanceKm >= 15, trip.maxSpeed >= 100 {
            items.append(
                RideMoment(
                    id: "long-haul",
                    title: "Distance run",
                    value: String(format: "%.0f km", trip.distanceKm),
                    detail: "A proper mileage day with highway pace",
                    systemImage: "point.bottomleft.forward.to.point.topright.scurvepath"
                )
            )
        }

        return items
    }

    // MARK: - Route helpers

    private struct AltitudeSegment {
        let gain: Double
        let endTime: TimeInterval
    }

    private struct StopSegment {
        let duration: Int64
        let startTime: TimeInterval
    }

    private static func bestAltitudeSegment(_ points: [RoutePoint], ascending: Bool) -> AltitudeSegment? {
        guard points.count >= 3 else { return nil }
        var peak = 0.0
        var peakEnd = points[0].timestamp
        var current = 0.0
        var prev = points[0].altitude

        for i in 1..<points.count {
            let alt = points[i].altitude
            let delta = ascending ? (alt - prev) : (prev - alt)
            if delta > 0.3 {
                current += delta
                if current > peak {
                    peak = current
                    peakEnd = points[i].timestamp
                }
            } else if delta < -0.5 {
                current = 0
            }
            prev = alt
        }
        return peak > 0 ? AltitudeSegment(gain: peak, endTime: peakEnd) : nil
    }

    private static func longestStopSegment(_ points: [RoutePoint]) -> StopSegment? {
        guard points.count >= 2 else { return nil }
        var bestDuration: Int64 = 0
        var bestStart: TimeInterval = points[0].timestamp
        var stopStart: TimeInterval?

        for point in points {
            if point.speedMps < stopSpeedMps {
                if stopStart == nil { stopStart = point.timestamp }
            } else if let start = stopStart {
                let duration = Int64(max(0, point.timestamp - start))
                if duration > bestDuration {
                    bestDuration = duration
                    bestStart = start
                }
                stopStart = nil
            }
        }

        if let start = stopStart, let last = points.last, last.speedMps < stopSpeedMps {
            let duration = Int64(max(0, last.timestamp - start))
            if duration > bestDuration {
                bestDuration = duration
                bestStart = start
            }
        }

        return bestDuration > 0 ? StopSegment(duration: bestDuration, startTime: bestStart) : nil
    }

    private static func distanceAlongRoute(to target: RoutePoint, in points: [RoutePoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        var total = 0.0
        for i in 1..<points.count {
            let a = points[i - 1]
            let b = points[i]
            total += haversineMeters(a.latitude, a.longitude, b.latitude, b.longitude)
            if b.id == target.id || abs(b.timestamp - target.timestamp) < 0.01 {
                break
            }
        }
        return total
    }

    private static func haversineMeters(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0
        let p1 = lat1 * .pi / 180
        let p2 = lat2 * .pi / 180
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(p1) * cos(p2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }

    private static func elapsedLabel(_ seconds: TimeInterval) -> String {
        RideFormatters.secondsToTime(Int64(seconds.rounded()))
    }
}
