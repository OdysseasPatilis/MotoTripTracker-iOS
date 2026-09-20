import SwiftUI
import UIKit

struct MetricTile: View {
    let label: String
    let value: String
    var valueColor: Color?
    let colors: AppPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(colors.textSecondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(valueColor ?? colors.textPrimary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(colors.bgCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct SpeedometerArc: View {
    let speedKmh: Double
    var maxSpeedKmh: Double = 260
    var speedLimitKmh: Double = 50
    let colors: AppPalette

    private var isOverLimit: Bool { speedKmh > speedLimitKmh }
    private var speedPercent: Double { min(max(speedKmh / maxSpeedKmh, 0), 1) }
    private var limitPercent: Double { min(max(speedLimitKmh / maxSpeedKmh, 0), 1) }

    var body: some View {
        ZStack {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let padding: CGFloat = 20
                let radius = (min(size.width, size.height) - padding * 2) / 2
                let startAngle = Angle.degrees(135)
                let sweep = 270.0
                let mainWidth: CGFloat = 9

                func arc(from startFraction: Double, to endFraction: Double) -> Path {
                    var path = Path()
                    path.addArc(
                        center: center,
                        radius: radius,
                        startAngle: startAngle + Angle.degrees(sweep * startFraction),
                        endAngle: startAngle + Angle.degrees(sweep * endFraction),
                        clockwise: false
                    )
                    return path
                }

                // Track
                context.stroke(
                    arc(from: 0, to: 1),
                    with: .color(colors.arcTrack),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )

                if speedPercent > 0 {
                    let accent = isOverLimit ? colors.stopRed : colors.neonGreen
                    let progress = arc(from: 0, to: speedPercent)

                    // Neon glow underlay
                    context.drawLayer { layer in
                        layer.addFilter(.blur(radius: 8))
                        layer.stroke(
                            progress,
                            with: .color(accent.opacity(0.55)),
                            style: StrokeStyle(lineWidth: 16, lineCap: .round)
                        )
                    }

                    // Core arc — green up to the limit, red beyond it
                    if !isOverLimit {
                        context.stroke(
                            progress,
                            with: .color(colors.neonGreen),
                            style: StrokeStyle(lineWidth: mainWidth, lineCap: .round)
                        )
                    } else {
                        context.stroke(
                            arc(from: 0, to: limitPercent),
                            with: .color(colors.neonGreen.opacity(0.6)),
                            style: StrokeStyle(lineWidth: mainWidth, lineCap: .round)
                        )
                        context.stroke(
                            arc(from: limitPercent, to: speedPercent),
                            with: .color(colors.stopRed),
                            style: StrokeStyle(lineWidth: mainWidth, lineCap: .round)
                        )
                    }
                }

                // Speed limit notch on the ring
                let limitAngle = (135 + sweep * limitPercent) * .pi / 180
                let notchInner = radius - 9
                let notchOuter = radius + 9
                var notch = Path()
                notch.move(to: CGPoint(
                    x: center.x + notchInner * cos(limitAngle),
                    y: center.y + notchInner * sin(limitAngle)
                ))
                notch.addLine(to: CGPoint(
                    x: center.x + notchOuter * cos(limitAngle),
                    y: center.y + notchOuter * sin(limitAngle)
                ))
                context.stroke(
                    notch,
                    with: .color(colors.textPrimary.opacity(0.9)),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
            }
            .frame(width: 260, height: 260)

            VStack(spacing: 6) {
                SpeedLimitSign(
                    limitKmh: Int(speedLimitKmh),
                    isOverLimit: isOverLimit
                )
                .allowsHitTesting(false)
                .accessibilityLabel("Speed limit \(Int(speedLimitKmh)) kilometers per hour")

                Text("\(Int(speedKmh))")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundStyle(isOverLimit ? colors.stopRed : colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                Text("km/h")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(colors.textSecondary)
            }
        }
        .frame(width: 260, height: 260)
        .animation(.easeInOut(duration: 0.35), value: speedKmh)
    }
}

enum OverLimitFlashPhase: Int {
    case red = 0
    case blue = 1
    case white = 2

    static func current(at date: Date) -> OverLimitFlashPhase {
        OverLimitFlashPhase(rawValue: Int(date.timeIntervalSinceReferenceDate / 0.16) % 3) ?? .red
    }

    var fill: Color {
        switch self {
        case .red: Color(hex: 0xE30613)
        case .blue: Color(hex: 0x0055FF)
        case .white: .white
        }
    }

    var ring: Color {
        switch self {
        case .red, .blue: .white
        case .white: Color(hex: 0xE30613)
        }
    }

    var number: Color {
        switch self {
        case .red, .blue: .white
        case .white: .black
        }
    }
}

struct OverLimitScreenFlash: View {
    /// Full-screen flash starts this far above the posted limit (km/h). Sign still flashes sooner.
    static let screenFlashToleranceKmh = 10

    let isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.16, paused: !isActive)) { context in
            if isActive {
                OverLimitFlashPhase.current(at: context.date).fill
                    .opacity(0.22)
                    .animation(.easeInOut(duration: 0.12), value: OverLimitFlashPhase.current(at: context.date).rawValue)
            }
        }
    }
}

struct SpeedLimitSign: View {
    let limitKmh: Int
    let isOverLimit: Bool

    var body: some View {
        Group {
            if isOverLimit {
                TimelineView(.animation(minimumInterval: 0.16)) { context in
                    badge(phase: OverLimitFlashPhase.current(at: context.date))
                }
            } else {
                badge(fill: .white, ring: Color(hex: 0xE30613), number: .black, glowing: false)
            }
        }
        .allowsHitTesting(false)
    }

    private func badge(phase: OverLimitFlashPhase) -> some View {
        badge(fill: phase.fill, ring: phase.ring, number: phase.number, glowing: true)
    }

    private func badge(fill: Color, ring: Color, number: Color, glowing: Bool) -> some View {
        ZStack {
            Circle()
                .fill(fill)
                .shadow(
                    color: glowing ? fill.opacity(0.55) : .black.opacity(0.25),
                    radius: glowing ? 8 : 3,
                    y: 1
                )
            Circle()
                .stroke(ring, lineWidth: 5.5)
            Text("\(limitKmh)")
                .font(.system(size: limitKmh >= 100 ? 18 : 22, weight: .bold, design: .rounded))
                .foregroundStyle(number)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(width: 54, height: 54)
    }
}

struct GForceBar: View {
    let value: Double
    let maxValue: Double
    let colors: AppPalette

    private var fillFraction: CGFloat {
        maxValue > 0 ? CGFloat(min(max(value / maxValue, 0), 1)) : 0
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(String(format: "%.2f G", value))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(colors.textPrimary)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(colors.arcTrack)
                    Capsule()
                        .fill(colors.startGradient)
                        .frame(width: max(geo.size.width * fillFraction, 0))
                }
            }
            .frame(width: 200, height: 6)

            Text(String(format: "Max %.2f G", maxValue))
                .font(.caption)
                .foregroundStyle(colors.textSecondary)
        }
    }
}

struct GpsSignalIndicator: View {
    let quality: GpsQuality
    var accuracyMeters: Double?
    let colors: AppPalette

    private var tint: Color {
        switch quality {
        case .excellent, .good: colors.neonGreen
        case .fair: colors.routeAmber
        case .poor: colors.neonRed
        case .unknown: colors.textMuted
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "location.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)

            GpsBarsIcon(filledBars: quality.barCount, tint: tint)

            Text(statusText)
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// Accuracy radius in meters (how precise the fix is), not distance ridden.
    private var statusText: String {
        if let meters = accuracyMeters, meters > 0 {
            return "±\(Int(meters.rounded()))m"
        }
        return "GPS"
    }

    private var accessibilityText: String {
        if let meters = accuracyMeters, meters > 0 {
            return "GPS \(quality.shortLabel), accuracy within \(Int(meters.rounded())) meters"
        }
        return "GPS \(quality.shortLabel)"
    }
}

private struct GpsBarsIcon: View {
    let filledBars: Int
    let tint: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(index < filledBars ? tint : tint.opacity(0.25))
                    .frame(width: 2.5, height: 5 + CGFloat(index) * 2.5)
            }
        }
        .frame(height: 13, alignment: .bottom)
    }
}

struct BatteryIndicator: View {
    let level: Int
    let colors: AppPalette

    private var fillColor: Color {
        if level <= 20 { return colors.neonRed }
        if level <= 50 { return colors.routeAmber }
        return colors.neonGreen
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: batterySymbol)
                .font(.caption)
                .foregroundStyle(fillColor)
            Text("\(level)%")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(colors.batteryLabel)
        }
        .accessibilityLabel("Battery \(level) percent")
    }

    private var batterySymbol: String {
        switch level {
        case 0...10: "battery.0percent"
        case 11...25: "battery.25percent"
        case 26...50: "battery.50percent"
        case 51...75: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

enum BatteryReader {
    static func currentLevel() -> Int {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        if level < 0 { return 100 }
        // Round to nearest percent (truncation made 48.6% show as 48, etc.).
        return Int((Double(level) * 100).rounded())
    }
}
