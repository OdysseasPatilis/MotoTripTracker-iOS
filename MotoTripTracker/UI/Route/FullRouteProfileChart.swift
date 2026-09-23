import SwiftUI

struct FullRouteProfileChart: View {
    let points: [RoutePoint]
    let selectedLayer: MapLayer
    let tripDistanceKm: Double
    let colors: AppPalette

    var body: some View {
        let values: [Double] = points.map { point in
            selectedLayer == .elevation ? point.altitude : point.speedMps * 3.6
        }
        let lineColor = selectedLayer == .elevation ? colors.neonBlue : colors.routeTeal
        let fillColor = lineColor.opacity(0.12)
        let peak = values.max() ?? 0
        let peakLabel = selectedLayer == .elevation
            ? "+\(Int(peak)) m peak"
            : "\(Int(peak)) km/h peak"
        let peakColor = selectedLayer == .elevation ? colors.neonBlue : colors.routeCoral

        VStack(alignment: .leading, spacing: 8) {
            Text(selectedLayer == .elevation ? "Elevation profile" : "Speed profile")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(colors.textPrimary)

            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(colors.bgCard))

                guard values.count > 1 else { return }

                let pad: CGFloat = 10
                let minV = values.min() ?? 0
                let maxV = values.max() ?? 1
                let range = max(maxV - minV, 1)
                let usableWidth = size.width - pad * 2
                let usableHeight = size.height - pad * 2

                func point(at index: Int) -> CGPoint {
                    let x = pad + usableWidth * CGFloat(index) / CGFloat(values.count - 1)
                    let y = pad + usableHeight * (1 - CGFloat((values[index] - minV) / range))
                    return CGPoint(x: x, y: y)
                }

                var path = Path()
                for index in values.indices {
                    let p = point(at: index)
                    if index == 0 {
                        path.move(to: p)
                    } else {
                        path.addLine(to: p)
                    }
                }

                var fill = path
                fill.addLine(to: CGPoint(x: pad + usableWidth, y: size.height - pad))
                fill.addLine(to: CGPoint(x: pad, y: size.height - pad))
                fill.closeSubpath()
                context.fill(fill, with: .color(fillColor))
                context.stroke(path, with: .color(lineColor), lineWidth: 2)
            }
            .frame(height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .id(selectedLayer)

            HStack {
                Text("0 km")
                    .font(.caption2)
                    .foregroundStyle(colors.textSecondary)
                Spacer()
                Text(peakLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(peakColor)
                Spacer()
                Text(String(format: "%.1f km", tripDistanceKm))
                    .font(.caption2)
                    .foregroundStyle(colors.textSecondary)
            }
        }
    }
}

struct FullRouteLegendCaption: View {
    let selectedLayer: MapLayer
    let colors: AppPalette

    var body: some View {
        let text: String = selectedLayer == .speed
            ? "Slower → Faster"
            : "Low · Mid · High elevation thirds"
        Text(text)
            .font(.caption)
            .foregroundStyle(colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
