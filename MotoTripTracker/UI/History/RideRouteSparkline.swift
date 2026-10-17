import SwiftUI

/// A small route thumbnail for a history row, drawn from the saved polyline.
struct RideRouteSparkline: View {
    let encodedPolyline: String?
    let colors: AppPalette

    var body: some View {
        let points = RideRouteSparklinePath.normalizedPoints(encoded: encodedPolyline)
        ZStack {
            if points.count >= 2 {
                RideSparklineShape(points: points)
                    .stroke(
                        LinearGradient(
                            colors: [colors.routeTeal, colors.neonBlue, colors.routeCoral],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                    )
            } else {
                Image(systemName: "bicycle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(colors.neonGreen)
            }
        }
        .frame(width: 64, height: 48)
        .background(colors.bgPanel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Unit-box points for a route thumbnail. North is up.
enum RideRouteSparklinePath {
    static let maxPoints = 28

    static func normalizedPoints(encoded: String?) -> [CGPoint] {
        guard let encoded, !encoded.isEmpty else { return [] }
        let sampled = sample(PolylineEncoder.decode(encoded), limit: maxPoints)
        guard sampled.count >= 2 else { return [] }

        let minLat = sampled.map(\.lat).min() ?? 0
        let maxLat = sampled.map(\.lat).max() ?? 0
        let minLng = sampled.map(\.lng).min() ?? 0
        let maxLng = sampled.map(\.lng).max() ?? 0
        let midLat = (minLat + maxLat) / 2
        let cosLat = cos(midLat * .pi / 180)

        let xs = sampled.map { ($0.lng - minLng) * cosLat }
        let ys = sampled.map { $0.lat - minLat }
        let maxX = xs.max() ?? 0
        let maxY = ys.max() ?? 0
        let span = max(maxX, maxY, 1e-9)
        let xOffset = (span - maxX) / 2
        let yOffset = (span - maxY) / 2
        let pad = 0.14
        let usable = 1 - pad * 2

        return zip(xs, ys).map { x, y in
            let nx = (x + xOffset) / span
            let ny = (y + yOffset) / span
            return CGPoint(x: pad + nx * usable, y: pad + (1 - ny) * usable)
        }
    }

    static func sample(
        _ coordinates: [(lat: Double, lng: Double)],
        limit: Int
    ) -> [(lat: Double, lng: Double)] {
        guard coordinates.count > limit, limit >= 2 else { return coordinates }
        let step = Double(coordinates.count - 1) / Double(limit - 1)
        return (0..<limit).map { index in
            coordinates[min(coordinates.count - 1, Int((Double(index) * step).rounded()))]
        }
    }
}

private struct RideSparklineShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: rect.minX + first.x * rect.width, y: rect.minY + first.y * rect.height))
        for point in points.dropFirst() {
            path.addLine(
                to: CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
            )
        }
        return path
    }
}
