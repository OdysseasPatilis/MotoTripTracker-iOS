import ActivityKit
import SwiftUI
import WidgetKit

struct RideLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideActivityAttributes.self) { context in
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(context.state.speedKmh)")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(context.state.isOverLimit ? WidgetBrand.neonRed : .white)
                        Text("km/h")
                            .font(.caption2)
                            .foregroundStyle(WidgetBrand.textSecondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Limit \(context.state.speedLimitKmh)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(WidgetBrand.neonRed.opacity(0.9))
                        Text(String(format: "%.1f km", context.state.distanceKm))
                            .font(.caption)
                            .foregroundStyle(WidgetBrand.textSecondary)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    if context.state.isPaused {
                        Text("Paused")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(WidgetBrand.neonBlue)
                    } else if !context.state.navigationSummary.isEmpty {
                        Text(context.state.navigationSummary)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(WidgetBrand.neonBlue)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Label(formatTime(context.state.movingTimeSeconds), systemImage: "clock")
                        Spacer()
                        if context.state.isOverLimit {
                            Text("Over limit")
                                .fontWeight(.semibold)
                                .foregroundStyle(WidgetBrand.neonRed)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(WidgetBrand.textSecondary)
                }
            } compactLeading: {
                Image(systemName: context.state.isPaused ? "pause.fill" : "gauge.with.dots.needle.67percent")
                    .foregroundStyle(context.state.isOverLimit ? WidgetBrand.neonRed : WidgetBrand.neonGreen)
            } compactTrailing: {
                Text("\(context.state.speedKmh)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(context.state.isOverLimit ? WidgetBrand.neonRed : .white)
            } minimal: {
                Text("\(context.state.speedKmh)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(context.state.isOverLimit ? WidgetBrand.neonRed : WidgetBrand.neonGreen)
            }
        }
    }

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<RideActivityAttributes>) -> some View {
        let over = context.state.isOverLimit
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(context.state.speedKmh)")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(over ? WidgetBrand.neonRed : .white)
                    Text("km/h")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(WidgetBrand.textSecondary)
                }
                if context.state.isPaused {
                    Text("Paused")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WidgetBrand.neonBlue)
                } else if !context.state.navigationSummary.isEmpty {
                    Text(context.state.navigationSummary)
                        .font(.caption)
                        .foregroundStyle(WidgetBrand.neonBlue)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                ZStack {
                    Circle()
                        .fill(.white)
                        .frame(width: 36, height: 36)
                    Circle()
                        .stroke(WidgetBrand.neonRed, lineWidth: 3)
                        .frame(width: 36, height: 36)
                    Text("\(context.state.speedLimitKmh)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                }
                Text(String(format: "%.1f km", context.state.distanceKm))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                Text(formatTime(context.state.movingTimeSeconds))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(WidgetBrand.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .activityBackgroundTint(over ? WidgetBrand.neonRed.opacity(0.22) : WidgetBrand.bgDeep.opacity(0.85))
        .activitySystemActionForegroundColor(.white)
    }

    private func formatTime(_ totalSeconds: Int64) -> String {
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
