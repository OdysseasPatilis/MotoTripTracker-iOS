import Foundation
import SwiftData

@Model
final class Trip {
    @Attribute(.unique) var id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
    var distanceMeters: Double
    var movingTime: Int64
    var stoppedTime: Int64
    var maxSpeed: Double
    var maxGForce: Double
    var elevationGain: Double
    var avgSpeed: Double
    var encodedRoutePolyline: String?
    var title: String?
    var isFavorite: Bool = false
    var maxLateralGForce: Double = 0
    var cornerCount: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \RoutePoint.trip)
    var routePoints: [RoutePoint]

    init(
        id: UUID = UUID(),
        startTime: TimeInterval = 0,
        endTime: TimeInterval = 0,
        distanceMeters: Double = 0,
        movingTime: Int64 = 0,
        stoppedTime: Int64 = 0,
        maxSpeed: Double = 0,
        maxGForce: Double = 0,
        elevationGain: Double = 0,
        avgSpeed: Double = 0,
        encodedRoutePolyline: String? = nil,
        title: String? = nil,
        isFavorite: Bool = false,
        maxLateralGForce: Double = 0,
        cornerCount: Int = 0,
        routePoints: [RoutePoint] = []
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.distanceMeters = distanceMeters
        self.movingTime = movingTime
        self.stoppedTime = stoppedTime
        self.maxSpeed = maxSpeed
        self.maxGForce = maxGForce
        self.elevationGain = elevationGain
        self.avgSpeed = avgSpeed
        self.encodedRoutePolyline = encodedRoutePolyline
        self.title = title
        self.isFavorite = isFavorite
        self.maxLateralGForce = maxLateralGForce
        self.cornerCount = cornerCount
        self.routePoints = routePoints
    }

    var totalTime: Int64 { movingTime + stoppedTime }
    var distanceKm: Double { distanceMeters / 1000 }

    var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return "Ride \(RideFormatters.timestampToDate(startTime))"
    }
}
