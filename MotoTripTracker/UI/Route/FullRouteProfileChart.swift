import SwiftUI

struct RideProfileSample: Equatable {
    var fraction: Double
    var value: Double
}

/// Smoothed speed or climb curve for the replay sheet.
enum RideProfileSeries {
    static let maxSamples = 80

    static func make(points: [RoutePoint], layer: MapLayer) -> [RideProfileSample] {
        guard points.count >= 2,
              let start = points.first?.timestamp,
              let end = points.last?.timestamp else { return [] }
        let span = max(end - start, 0.001)
        let floor = layer == .elevation ? (points.map(\.altitude).min() ?? 0) : 0
        let raw = sample(points, limit: maxSamples).map { point in
            let fraction = min(1, max(0, (point.timestamp - start) / span))
            let value: Double
            if layer == .elevation {
                value = max(0, point.altitude - floor)
            } else {
                value = max(0, point.speedMps * 3.6)
            }
            return RideProfileSample(fraction: fraction, value: value)
        }
        let smoothed = smooth(raw.map(\.value), radius: 2)
        return zip(raw, smoothed).map { sample, value in
            RideProfileSample(fraction: sample.fraction, value: value)
        }
    }

    static func value(at fraction: Double, in samples: [RideProfileSample]) -> Double {
        guard let first = samples.first else { return 0 }
        let target = min(1, max(0, fraction))
        if target <= first.fraction { return first.value }
        for index in 1..<samples.count {
            let previous = samples[index - 1]
            let next = samples[index]
            if target <= next.fraction {
                let span = next.fraction - previous.fraction
                let t = span > 0 ? (target - previous.fraction) / span : 0
                return previous.value + (next.value - previous.value) * t
            }
        }
        return samples.last?.value ?? first.value
    }

    static func peak(in samples: [RideProfileSample]) -> RideProfileSample? {
        samples.max { $0.value < $1.value }
    }

    private static func sample(_ points: [RoutePoint], limit: Int) -> [RoutePoint] {
        guard points.count > limit, limit >= 2 else { return points }
        let step = Double(points.count - 1) / Double(limit - 1)
        return (0..<limit).map { index in
            points[min(points.count - 1, Int((Double(index) * step).rounded()))]
        }
    }

    private static func smooth(_ values: [Double], radius: Int) -> [Double] {
        guard radius > 0, values.count > radius * 2 + 1 else { return values }
        return values.indices.map { index in
            let lower = max(0, index - radius)
            let upper = min(values.count - 1, index + radius)
            let slice = values[lower...upper]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }
}

struct FullRouteProfileChart: View {
    let points: [RoutePoint]
    let selectedLayer: MapLayer
    let tripDistanceKm: Double
    /// 0...1 along the ride while replaying or scrubbing. Hidden when nil.
    var playheadFraction: Double?
    let colors: AppPalette

    var body: some View {
        let samples = RideProfileSeries.make(points: points, layer: selectedLayer)
        let peak = RideProfileSeries.peak(in: samples)
        let playheadValue = playheadFraction.map { RideProfileSeries.value(at: $0, in: samples) }

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(selectedLayer == .elevation ? "Elevation" : "Speed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(colors.textPrimary)
                Spacer(minLength: 8)
                Text(headerValue(playhead: playheadValue, peak: peak))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(selectedLayer == .elevation ? colors.neonBlue : colors.routeCoral)
            }

            chart(samples: samples, peak: peak)
                .frame(height: 156)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            HStack {
                Text("0 km")
                Spacer()
                Text(String(format: "%.1f km", tripDistanceKm))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(colors.textSecondary)
        }
    }

    private func headerValue(playhead: Double?, peak: RideProfileSample?) -> String {
        if let playhead {
            return formatted(playhead)
        }
        guard let peak else { return selectedLayer == .elevation ? "0 m" : "0 km/h" }
        if selectedLayer == .elevation {
            return "\(Int(peak.value.rounded())) m climb"
        }
        return "\(Int(peak.value.rounded())) km/h peak"
    }

    private func formatted(_ value: Double) -> String {
        if selectedLayer == .elevation {
            return "\(Int(value.rounded())) m"
        }
        return "\(Int(value.rounded())) km/h"
    }

    private func chart(samples: [RideProfileSample], peak: RideProfileSample?) -> some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(
                Path(roundedRect: rect, cornerRadius: 16),
                with: .color(colors.bgCard)
            )

            let pad = CGSize(width: 16, height: 22)
            let plot = CGRect(
                x: pad.width,
                y: pad.height,
                width: max(1, size.width - pad.width * 2),
                height: max(1, size.height - pad.height * 2)
            )
            var baseline = Path()
            baseline.move(to: CGPoint(x: plot.minX, y: plot.maxY))
            baseline.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
            context.stroke(baseline, with: .color(colors.divider.opacity(0.7)), lineWidth: 1)

            guard samples.count > 1 else { return }

            let maxValue = max(samples.map(\.value).max() ?? 1, 1)
            func locate(_ sample: RideProfileSample) -> CGPoint {
                let x = plot.minX + plot.width * CGFloat(sample.fraction)
                let y = plot.maxY - plot.height * CGFloat(sample.value / maxValue)
                return CGPoint(x: x, y: y)
            }

            var line = Path()
            line.move(to: locate(samples[0]))
            for sample in samples.dropFirst() {
                line.addLine(to: locate(sample))
            }

            var fill = line
            fill.addLine(to: CGPoint(x: locate(samples[samples.count - 1]).x, y: plot.maxY))
            fill.addLine(to: CGPoint(x: locate(samples[0]).x, y: plot.maxY))
            fill.closeSubpath()

            if selectedLayer == .elevation {
                context.fill(
                    fill,
                    with: .linearGradient(
                        Gradient(colors: [colors.neonBlue.opacity(0.42), colors.neonBlue.opacity(0.02)]),
                        startPoint: CGPoint(x: plot.midX, y: plot.minY),
                        endPoint: CGPoint(x: plot.midX, y: plot.maxY)
                    )
                )
                context.stroke(line, with: .color(colors.neonBlue), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            } else {
                let gradient = Gradient(colors: [colors.routeTeal, colors.neonBlue, colors.routeCoral])
                let wash = Gradient(colors: [
                    colors.routeTeal.opacity(0.38),
                    colors.neonBlue.opacity(0.28),
                    colors.routeCoral.opacity(0.38)
                ])
                context.fill(
                    fill,
                    with: .linearGradient(
                        wash,
                        startPoint: CGPoint(x: plot.minX, y: plot.midY),
                        endPoint: CGPoint(x: plot.maxX, y: plot.midY)
                    )
                )
                context.stroke(
                    line,
                    with: .linearGradient(
                        gradient,
                        startPoint: CGPoint(x: plot.minX, y: plot.midY),
                        endPoint: CGPoint(x: plot.maxX, y: plot.midY)
                    ),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                )
            }

            if let peak, peak.value > 0 {
                let nearPlayhead = playheadFraction.map { abs($0 - peak.fraction) < 0.08 } ?? false
                if !nearPlayhead {
                    mark(context: &context, at: locate(peak), label: formatted(peak.value), plot: plot, fill: colors.bgDeep, stroke: selectedLayer == .elevation ? colors.neonBlue : colors.routeCoral)
                }
            }

            if let playheadFraction {
                let value = RideProfileSeries.value(at: playheadFraction, in: samples)
                let point = locate(RideProfileSample(fraction: min(1, max(0, playheadFraction)), value: value))
                var guide = Path()
                guide.move(to: CGPoint(x: point.x, y: plot.maxY))
                guide.addLine(to: point)
                context.stroke(guide, with: .color(colors.textPrimary.opacity(0.45)), lineWidth: 1)
                mark(context: &context, at: point, label: formatted(value), plot: plot, fill: colors.neonGreen, stroke: colors.bgDeep)
            }
        }
    }

    private func mark(
        context: inout GraphicsContext,
        at point: CGPoint,
        label: String,
        plot: CGRect,
        fill: Color,
        stroke: Color
    ) {
        let dot = CGRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9)
        context.fill(Path(ellipseIn: dot), with: .color(fill))
        context.stroke(Path(ellipseIn: dot), with: .color(stroke), lineWidth: 1.5)

        let resolved = context.resolve(
            Text(label)
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(colors.textPrimary)
        )
        let textSize = resolved.measure(in: CGSize(width: 80, height: 20))
        var origin = CGPoint(x: point.x - textSize.width / 2, y: point.y - textSize.height - 8)
        origin.x = min(max(plot.minX, origin.x), plot.maxX - textSize.width)
        if origin.y < plot.minY - 16 {
            origin.y = point.y + 8
        }
        context.draw(resolved, at: CGPoint(x: origin.x + textSize.width / 2, y: origin.y + textSize.height / 2), anchor: .center)
    }
}

struct FullRouteLegendCaption: View {
    let selectedLayer: MapLayer
    let colors: AppPalette

    var body: some View {
        let text: String = selectedLayer == .speed
            ? "Teal is slower, coral is faster"
            : "Height above the lowest point of this ride"
        Text(text)
            .font(.caption)
            .foregroundStyle(colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
