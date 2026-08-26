import Foundation

struct RideMoment: Equatable, Sendable, Identifiable {
    var id: String { title }
    let title: String
    let value: String
    let detail: String
}

struct RideMoments: Equatable, Sendable {
    let moments: [RideMoment]
}

enum RideMomentsCalculator {
    private static let stopSpeedMps = 0.5
    private static let minStopSeconds: Int64 = 15
    private static let minClimbMeters = 8.0

    static func calculate(trip: Trip, points: [RoutePoint]) -> RideMoments {
        let sorted = points.sorted { $0.timestamp < $1.timestamp }
        var moments: [RideMoment] = []

        if trip.maxSpeed > 0 {
            moments.append(
                RideMoment(
                    title: "Top speed",
                    value: "\(Int(trip.maxSpeed)) km/h",
                    detail: "Peak velocity this ride"
                )
            )
        }
        if trip.maxGForce > 0 {
            moments.append(
                RideMoment(
                    title: "Max G",
                    value: String(format: "%.2f G", trip.maxGForce),
                    detail: "Hardest acceleration spike"
                )
            )
        }
        if trip.elevationGain >= 5 {
            moments.append(
                RideMoment(
                    title: "Elevation",
                    value: "+\(Int(trip.elevationGain)) m",
                    detail: "Total climbing"
                )
            )
        }

        if let stopSec = longestStopSeconds(sorted), stopSec >= minStopSeconds {
            moments.append(
                RideMoment(
                    title: "Longest stop",
                    value: RideFormatters.secondsToTime(stopSec),
                    detail: "Longest pause while recording"
                )
            )
        }

        if let climb = peakClimbMeters(sorted), climb >= minClimbMeters {
            moments.append(
                RideMoment(
                    title: "Biggest climb",
                    value: "+\(Int(climb)) m",
                    detail: "Steepest continuous ascent"
                )
            )
        }

        if trip.avgSpeed > 0, trip.movingTime > 0 {
            moments.append(
                RideMoment(
                    title: "Moving pace",
                    value: "\(Int(trip.avgSpeed)) km/h",
                    detail: "Average while moving"
                )
            )
        }

        if trip.maxLateralGForce > 0.15 {
            moments.append(
                RideMoment(
                    title: "Max lean G",
                    value: String(format: "%.2f G", trip.maxLateralGForce),
                    detail: "Peak lateral force"
                )
            )
        }

        if trip.cornerCount > 0 {
            moments.append(
                RideMoment(
                    title: "Corners",
                    value: "\(trip.cornerCount)",
                    detail: "Detected turns this ride"
                )
            )
        }

        return RideMoments(moments: Array(moments.prefix(8)))
    }

    private static func longestStopSeconds(_ points: [RoutePoint]) -> Int64? {
        guard points.count >= 2 else { return nil }
        var longest: Int64 = 0
        var stopStart: TimeInterval?

        for point in points {
            if point.speedMps < stopSpeedMps {
                if stopStart == nil { stopStart = point.timestamp }
            } else if let start = stopStart {
                let duration = Int64(max(0, point.timestamp - start))
                longest = max(longest, duration)
                stopStart = nil
            }
        }

        if let start = stopStart, let last = points.last, last.speedMps < stopSpeedMps {
            longest = max(longest, Int64(max(0, last.timestamp - start)))
        }

        return longest > 0 ? longest : nil
    }

    private static func peakClimbMeters(_ points: [RoutePoint]) -> Double? {
        guard points.count >= 3 else { return nil }
        var peak = 0.0
        var currentClimb = 0.0
        var prevAlt = points[0].altitude

        for i in 1..<points.count {
            let alt = points[i].altitude
            let delta = alt - prevAlt
            if delta > 0.3 {
                currentClimb += delta
                peak = max(peak, currentClimb)
            } else if delta < -0.5 {
                currentClimb = 0
            }
            prevAlt = alt
        }

        return peak > 0 ? peak : nil
    }
}
