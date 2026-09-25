import CoreLocation
import MapKit
import SwiftUI
import UIKit

enum FullRouteMapStyling {
    struct Segment {
        let coordinates: [CLLocationCoordinate2D]
        let color: Color
    }

    static func mergedSegments(
        points: [RoutePoint],
        selectedLayer: MapLayer,
        usingPolylineFallback: Bool,
        colors: AppPalette
    ) -> [Segment] {
        let raw = segments(
            points: points,
            selectedLayer: selectedLayer,
            usingPolylineFallback: usingPolylineFallback,
            colors: colors
        )
        guard let first = raw.first else { return [] }
        var merged: [Segment] = []
        var currentCoords = first.coordinates
        var currentColor = first.color

        for segment in raw.dropFirst() {
            if colorsApproximatelyEqual(segment.color, currentColor) {
                if let last = segment.coordinates.last {
                    currentCoords.append(last)
                }
            } else {
                merged.append(Segment(coordinates: currentCoords, color: currentColor))
                currentCoords = segment.coordinates
                currentColor = segment.color
            }
        }
        merged.append(Segment(coordinates: currentCoords, color: currentColor))
        return merged
    }

    static func iconName(for type: String?) -> String {
        switch type {
        case "START": return "flag.fill"
        case "END": return "flag.checkered"
        case "TOP_SPEED": return "gauge.with.dots.needle.67percent"
        case "SUMMIT": return "mountain.2.fill"
        case "STOP_SIGN": return "stop.circle.fill"
        case "TRAFFIC_LIGHT": return "light.beacon.max.fill"
        case "BRIEF_STOP", "REST_STOP": return "cup.and.saucer.fill"
        default: return "mappin.circle.fill"
        }
    }

    static func markerColor(for type: String?, colors: AppPalette) -> Color {
        switch type {
        case "START": return colors.neonGreen
        case "END": return colors.neonRed
        case "TOP_SPEED": return colors.routeAmber
        case "SUMMIT": return Color(hex: 0xD988FF)
        case "REST_STOP": return colors.neonBlue
        default: return colors.layerActive
        }
    }

    static func region(fitting coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard !coordinates.isEmpty else { return nil }
        var minLat = coordinates[0].latitude
        var maxLat = coordinates[0].latitude
        var minLng = coordinates[0].longitude
        var maxLng = coordinates[0].longitude
        for c in coordinates {
            minLat = min(minLat, c.latitude)
            maxLat = max(maxLat, c.latitude)
            minLng = min(minLng, c.longitude)
            maxLng = max(maxLng, c.longitude)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: (minLng + maxLng) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.4, 0.01),
                longitudeDelta: max((maxLng - minLng) * 1.4, 0.01)
            )
        )
    }

    private static func segments(
        points: [RoutePoint],
        selectedLayer: MapLayer,
        usingPolylineFallback: Bool,
        colors: AppPalette
    ) -> [Segment] {
        guard points.count > 1 else { return [] }
        let altitudes = points.map(\.altitude)
        let minE = altitudes.min() ?? 0
        let maxE = altitudes.max() ?? 0
        let speedsKmh = points.map { $0.speedMps * 3.6 }
        let minS = speedsKmh.min() ?? 0
        let maxS = speedsKmh.max() ?? 0

        var result: [Segment] = []
        for i in 0..<(points.count - 1) {
            let a = points[i]
            let b = points[i + 1]
            let color: Color
            if usingPolylineFallback {
                color = colors.neonBlue
            } else if selectedLayer == .speed {
                let kmh = a.speedMps * 3.6
                let t = maxS > minS ? (kmh - minS) / (maxS - minS) : 0.5
                color = speedGradientColor(t: t, colors: colors)
            } else {
                let elev = a.altitude
                let t = maxE > minE ? (elev - minE) / (maxE - minE) : 0.5
                color = t < 0.33 ? colors.routeTeal : (t < 0.66 ? colors.neonBlue : colors.routeCoral)
            }
            result.append(
                Segment(
                    coordinates: [
                        CLLocationCoordinate2D(latitude: a.latitude, longitude: a.longitude),
                        CLLocationCoordinate2D(latitude: b.latitude, longitude: b.longitude)
                    ],
                    color: color
                )
            )
        }
        return result
    }

    private static func colorsApproximatelyEqual(_ a: Color, _ b: Color) -> Bool {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        UIColor(a).getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        UIColor(b).getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return abs(ar - br) < 0.02 && abs(ag - bg) < 0.02 && abs(ab - bb) < 0.02
    }

    /// Continuous teal → blue → coral by relative speed (no Slow / Cruise / Fast buckets).
    private static func speedGradientColor(t: Double, colors: AppPalette) -> Color {
        let clamped = min(max(t, 0), 1)
        if clamped < 0.5 {
            return blend(colors.routeTeal, colors.neonBlue, amount: clamped * 2)
        }
        return blend(colors.neonBlue, colors.routeCoral, amount: (clamped - 0.5) * 2)
    }

    private static func blend(_ a: Color, _ b: Color, amount: Double) -> Color {
        let t = min(max(amount, 0), 1)
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        UIColor(a).getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        UIColor(b).getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return Color(
            red: Double(ar + (br - ar) * t),
            green: Double(ag + (bg - ag) * t),
            blue: Double(ab + (bb - ab) * t),
            opacity: Double(aa + (ba - aa) * t)
        )
    }
}
