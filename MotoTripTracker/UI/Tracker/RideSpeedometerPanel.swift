import SwiftUI

struct RideSpeedometerPanel: View {
    let stats: TripStats
    let speedLimitKmh: Int
    let colors: AppPalette

    var body: some View {
        VStack(spacing: 20) {
            speedometerCard
            statsGrid
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 24)
    }

    private var speedometerCard: some View {
        VStack(spacing: 14) {
            SpeedometerArc(
                speedKmh: stats.speed,
                maxSpeedKmh: max(stats.maxSpeed, 260),
                speedLimitKmh: Double(speedLimitKmh),
                colors: colors
            )
            GForceBar(
                value: stats.currentGForce,
                maxValue: max(stats.maxGForce, 0.01),
                colors: colors
            )
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .background(colors.bgCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var statsGrid: some View {
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        let metrics: [(String, String, Color?)] = [
            ("Distance", String(format: "%.1f km", stats.distanceKm), nil),
            ("Total time", RideFormatters.secondsToTime(stats.tripTime), nil),
            ("Moving", RideFormatters.secondsToTime(stats.movingTime), colors.neonGreen),
            ("Stopped", RideFormatters.secondsToTime(stats.stoppedTime), colors.neonRed),
            ("Avg speed", "\(Int(stats.avgSpeed.rounded())) km/h", nil),
            ("Max speed", String(format: "%.1f km/h", stats.maxSpeed), nil),
            ("Elevation", "\(Int(stats.totalElevationGain)) m", nil),
            ("Max G", String(format: "%.2f G", stats.maxGForce), colors.neonBlue),
            ("Lateral G", String(format: "%.2f G", stats.currentLateralGForce), colors.neonBlue),
            ("Twistiness", twistinessLabel, colors.neonBlue)
        ]

        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(Array(metrics.enumerated()), id: \.offset) { _, metric in
                MetricTile(
                    label: metric.0,
                    value: metric.1,
                    valueColor: metric.2,
                    colors: colors
                )
            }
        }
    }

    private var twistinessLabel: String {
        let score = TwistinessCalculator.score(
            cornerCount: stats.cornerCount,
            distanceKm: stats.distanceKm,
            maxLateralGForce: stats.maxLateralGForce
        )
        guard score > 0 else { return "—" }
        return TwistinessCalculator.formattedScore(score)
    }
}
