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

    /// Full postal-style address when MapKit provides one.
    static func fullAddress(of item: MKMapItem) -> String? {
        if let full = item.address?.fullAddress, !full.isEmpty {
            return full
        }
        return shortAddress(of: item)
    }

    static func categoryLabel(of item: MKMapItem) -> String? {
        guard let category = item.pointOfInterestCategory else { return nil }
        let raw = category.rawValue
        let trimmed = raw
            .replacingOccurrences(of: "MKPOICategory", with: "")
            .replacingOccurrences(of: "POICategory", with: "")
        guard !trimmed.isEmpty else { return nil }
        // "gasStation" / "GasStation" → "Gas Station"
        let spaced = trimmed.unicodeScalars.reduce(into: "") { result, scalar in
            if CharacterSet.uppercaseLetters.contains(scalar), !result.isEmpty {
                result.append(" ")
            }
            result.append(String(scalar))
        }
        return spaced.capitalized
    }

    static func phoneNumber(of item: MKMapItem) -> String? {
        let phone = item.phoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let phone, !phone.isEmpty else { return nil }
        return phone
    }

    static func websiteHost(of item: MKMapItem) -> String? {
        guard let url = item.url else { return nil }
        if let host = url.host, !host.isEmpty {
            return host.replacingOccurrences(of: "www.", with: "")
        }
        let absolute = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        return absolute.isEmpty ? nil : absolute
    }

    static func websiteURL(of item: MKMapItem) -> URL? {
        item.url
    }
}
