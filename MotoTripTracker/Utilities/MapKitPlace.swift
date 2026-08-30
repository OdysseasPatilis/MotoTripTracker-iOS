import CoreLocation
import MapKit

/// iOS 26+ MapKit helpers that avoid deprecated `MKPlacemark` / `placemark` APIs.
nonisolated enum MapKitPlace {
    static func mapItem(coordinate: CLLocationCoordinate2D, name: String? = nil) -> MKMapItem {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let item = MKMapItem(location: location, address: nil)
        item.name = name
        return item
    }

    static func coordinate(of item: MKMapItem) -> CLLocationCoordinate2D {
        item.location.coordinate
    }

    /// Short street / locality line for list UI.
    static func shortAddress(of item: MKMapItem) -> String? {
        if let short = item.address?.shortAddress, !short.isEmpty {
            return short
        }
        if let city = item.addressRepresentations?.cityWithContext, !city.isEmpty {
            return city
        }
        if let city = item.addressRepresentations?.cityName, !city.isEmpty {
            return city
        }
        return nil
    }
}
