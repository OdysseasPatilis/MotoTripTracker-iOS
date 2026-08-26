import Foundation

enum GpxExporter {
    static func build(trip: Trip, points: [RoutePoint]) -> String {
        let sorted = points.sorted { $0.timestamp < $1.timestamp }
        let name = escapeXML(trip.displayTitle)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var lines: [String] = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<gpx version="1.1" creator="MotoTripTracker" xmlns="http://www.topografix.com/GPX/1/1">"#,
            "  <metadata>",
            "    <name>\(name)</name>"
        ]

        if trip.startTime > 0 {
            lines.append("    <time>\(formatter.string(from: Date(timeIntervalSince1970: trip.startTime)))</time>")
        }

        lines.append(contentsOf: [
            "  </metadata>",
            "  <trk>",
            "    <name>\(name)</name>",
            "    <trkseg>"
        ])

        for point in sorted {
            lines.append(#"      <trkpt lat="\#(point.latitude)" lon="\#(point.longitude)">"#)
            lines.append("        <ele>\(point.altitude)</ele>")
            if point.timestamp > 0 {
                lines.append(
                    "        <time>\(formatter.string(from: Date(timeIntervalSince1970: point.timestamp)))</time>"
                )
            }
            lines.append("      </trkpt>")
        }

        lines.append(contentsOf: [
            "    </trkseg>",
            "  </trk>",
            "</gpx>"
        ])

        return lines.joined(separator: "\n")
    }

    private static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
