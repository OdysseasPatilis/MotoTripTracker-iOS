import CoreLocation
import Foundation
import MapKit

/// A single turn-by-turn maneuver extracted from `MKRoute.Step`.
struct NavStep: Sendable, Identifiable, Hashable {
    let id: UUID
    let instruction: String
    let distance: CLLocationDistance
    let endLatitude: Double
    let endLongitude: Double

    var endCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: endLatitude, longitude: endLongitude)
    }

    init(instruction: String, distance: CLLocationDistance, endCoordinate: CLLocationCoordinate2D) {
        self.id = UUID()
        self.instruction = instruction
        self.distance = distance
        self.endLatitude = endCoordinate.latitude
        self.endLongitude = endCoordinate.longitude
    }
}

enum NavigationPhase: String, Equatable, Sendable {
    case idle
    case previewing
    case navigating
}

struct NavRouteOption: Identifiable, Equatable, Sendable {
    let id: UUID
    let coordinates: [CLLocationCoordinate2D]
    let distanceMeters: Double
    /// MapKit automobile ETA (typically traffic-aware).
    let expectedTravelTime: TimeInterval
    /// Motorcycle-adjusted ETA (filters part of car traffic delay).
    let motoTravelTime: TimeInterval
    let trafficDelay: TimeInterval
    let steps: [NavStep]

    static func == (lhs: NavRouteOption, rhs: NavRouteOption) -> Bool {
        lhs.id == rhs.id
    }
}

extension MKPolyline {
    /// Extracts the polyline's vertices as an array of coordinates.
    var coordinates: [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(),
            count: pointCount
        )
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}
