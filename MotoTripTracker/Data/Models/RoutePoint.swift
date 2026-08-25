import Foundation
import SwiftData

@Model
final class RoutePoint {
    var id: UUID
    var latitude: Double
    var longitude: Double
    var altitude: Double
    var speedMps: Double
    var timestamp: TimeInterval
    var waypointType: String?
    var isWaypoint: Bool
    var waypointTitle: String
    var waypointSubtitle: String
    var trip: Trip?

    init(
        id: UUID = UUID(),
        latitude: Double,
        longitude: Double,
        altitude: Double,
        speedMps: Double,
        timestamp: TimeInterval,
        waypointType: String? = nil,
        isWaypoint: Bool = false,
        waypointTitle: String = "",
        waypointSubtitle: String = ""
    ) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.speedMps = speedMps
        self.timestamp = timestamp
        self.waypointType = waypointType
        self.isWaypoint = isWaypoint
        self.waypointTitle = waypointTitle
        self.waypointSubtitle = waypointSubtitle
    }
}
