import SwiftUI
import UIKit
import os

struct RideTrackerView: View {
    @Environment(AppContainer.self) private var app
    @Environment(ThemeStore.self) private var theme
    @State private var clock = RideFormatters.currentClock()
    @State private var batteryLevel = BatteryReader.currentLevel()

    private static let selectableSpeedLimits = [30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130]

    private var speedLimitKmh: Int { app.speedLimitService.effectiveLimitKmh }

    var body: some View {
        let session = app.tripManager.sessionState
        let stats = session.stats
        let colors = theme.palette

        ZStack {
            colors.bgDeep.ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 12) {
                        header(colors: colors)
                        speedometerCard(stats: stats, colors: colors)
                        statsGrid(stats: stats, colors: colors)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 12)
                }

                bottomBar(session: session, colors: colors)
            }
        }
        .onAppear {
            app.locationService.requestAuthorization()
            app.locationService.refreshLocationEnabled()
            UIApplication.shared.isIdleTimerDisabled = true
            if let location = app.locationService.lastLocation {
                app.speedLimitService.refresh(for: location)
            }
        }
        .onDisappear {
            if !session.isActive {
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                clock = RideFormatters.currentClock()
                batteryLevel = BatteryReader.currentLevel()
            }
        }
    }

    private func header(colors: AppPalette) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("RIDE TRACKER")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(2)
                    .foregroundStyle(colors.textMuted)
                Text(clock)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(colors.textPrimary)
            }
            Spacer()
            HStack(spacing: 10) {
                BatteryIndicator(level: batteryLevel, colors: colors)
                Button {
                    theme.toggle()
                } label: {
                    Image(systemName: theme.mode.toggleSymbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(colors.textMuted)
                        .frame(width: 32, height: 32)
                        .background(colors.bgPanel, in: Circle())
                }
                .accessibilityLabel("Switch to \(theme.mode.toggleLabel) theme")
                NavigationLink(value: AppRoute.history) {
                    Text("HISTORY")
                        .font(.system(size: 11, weight: .medium))
                        .tracking(1)
                        .foregroundStyle(colors.neonGreen)
                }
            }
        }
    }

    private func speedometerCard(stats: TripStats, colors: AppPalette) -> some View {
        VStack(spacing: 16) {
            SpeedometerArc(
                speedKmh: stats.speed,
                maxSpeedKmh: max(stats.maxSpeed, 260),
                speedLimitKmh: Double(speedLimitKmh),
                colors: colors,
                isAutoLimit: app.speedLimitService.hasAutoLimit,
                onCycleSpeedLimit: cycleSpeedLimit,
                onClearManualOverride: clearManualSpeedLimit
            )
            GForceBar(
                value: stats.currentGForce,
                maxValue: max(stats.maxGForce, 0.01),
                colors: colors
            )
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .background(colors.bgPanel, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func cycleSpeedLimit() {
        let limits = Self.selectableSpeedLimits
        let current = app.speedLimitService.manualOverrideKmh ?? app.speedLimitService.autoLimitKmh ?? 50
        if let index = limits.firstIndex(of: current) {
            app.speedLimitService.manualOverrideKmh = limits[(index + 1) % limits.count]
        } else {
            app.speedLimitService.manualOverrideKmh = 50
        }
        AppLogger.speedLimit.info(
            "Manual override set → \(self.app.speedLimitService.manualOverrideKmh ?? -1) km/h (auto was \(self.app.speedLimitService.autoLimitKmh.map(String.init) ?? "none"))"
        )
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func clearManualSpeedLimit() {
        app.speedLimitService.clearManualOverride()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func statsGrid(stats: TripStats, colors: AppPalette) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                StatCard(label: "DISTANCE", value: String(format: "%.1f km", stats.distanceKm), colors: colors)
                StatCard(label: "TOTAL TIME", value: RideFormatters.secondsToTime(stats.tripTime), colors: colors)
            }
            HStack(spacing: 12) {
                StatCard(
                    label: "MOVING",
                    value: RideFormatters.secondsToTime(stats.movingTime),
                    valueColor: colors.neonGreen,
                    colors: colors
                )
                StatCard(
                    label: "STOPPED",
                    value: RideFormatters.secondsToTime(stats.stoppedTime),
                    valueColor: colors.neonRed,
                    colors: colors
                )
            }
            HStack(spacing: 12) {
                StatCard(label: "AVG SPEED", value: "\(Int(stats.avgSpeed)) km/h", colors: colors)
                StatCard(label: "MAX SPEED", value: "\(Int(stats.maxSpeed)) km/h", colors: colors)
            }
            HStack(spacing: 12) {
                StatCard(label: "ELEVATION", value: "\(Int(stats.totalElevationGain)) m", colors: colors)
                StatCard(
                    label: "MAX G",
                    value: String(format: "%.2f G", stats.maxGForce),
                    valueColor: colors.neonBlue,
                    colors: colors
                )
            }
        }
    }

    private func bottomBar(session: RideSessionState, colors: AppPalette) -> some View {
        HStack(spacing: 10) {
            if session.isActive {
                Button {
                    if session.isPaused {
                        app.resumeRide()
                    } else {
                        app.pauseRide()
                    }
                } label: {
                    HStack(spacing: 6) {
                        if !session.isPaused {
                            Circle()
                                .fill(colors.stopRed)
                                .frame(width: 8, height: 8)
                        }
                        Text(session.isPaused ? "RESUME" : "PAUSE")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .foregroundStyle(colors.textPrimary)
                    .background(colors.bgPanel, in: Capsule())
                    .overlay(Capsule().stroke(colors.pauseBorder, lineWidth: 1))
                }

                Button {
                    app.stopRide()
                    UIApplication.shared.isIdleTimerDisabled = false
                } label: {
                    Text("STOP")
                        .font(.system(size: 14, weight: .bold))
                        .tracking(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .foregroundStyle(colors.stopRed)
                        .background(colors.stopRed.opacity(0.15), in: Capsule())
                        .overlay(Capsule().stroke(colors.stopRed.opacity(0.3), lineWidth: 1))
                }
            } else {
                let enabled = app.locationService.isLocationEnabled
                Button {
                    app.startRide()
                } label: {
                    Text(enabled ? "START RIDE" : "ENABLE GPS TO START")
                        .font(.system(size: 16, weight: .bold))
                        .tracking(2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .foregroundStyle(enabled ? Color(hex: 0x0A0A0F) : colors.startButtonDisabledText)
                        .background {
                            if enabled {
                                colors.startGradient
                            } else {
                                colors.startButtonDisabledBg
                            }
                        }
                        .clipShape(Capsule())
                }
                .disabled(!enabled)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 24)
        .background(colors.bgDeep)
    }
}

struct StatCard: View {
    let label: String
    let value: String
    var valueColor: Color?
    let colors: AppPalette

    var body: some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .tracking(1)
                .foregroundStyle(colors.textMuted)
            Text(value)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(valueColor ?? colors.textPrimary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(colors.bgCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(colors.borderSubtle, lineWidth: 1)
        )
    }
}

struct SpeedometerArc: View {
    let speedKmh: Double
    var maxSpeedKmh: Double = 260
    var speedLimitKmh: Double = 50
    let colors: AppPalette
    var isAutoLimit: Bool = false
    var onCycleSpeedLimit: (() -> Void)?
    var onClearManualOverride: (() -> Void)?

    private var isOverLimit: Bool { speedKmh > speedLimitKmh }
    private var speedPercent: Double { min(max(speedKmh / maxSpeedKmh, 0), 1) }
    private var limitPercent: Double { min(max(speedLimitKmh / maxSpeedKmh, 0), 1) }

    var body: some View {
        ZStack {
            Canvas { context, size in
                let strokeWidth: CGFloat = 14
                let padding = strokeWidth / 2 + 4
                let rect = CGRect(
                    x: padding,
                    y: padding,
                    width: size.width - padding * 2,
                    height: size.height - padding * 2
                )
                let startAngle = Angle.degrees(150)

                var track = Path()
                track.addArc(
                    center: CGPoint(x: size.width / 2, y: size.height / 2),
                    radius: rect.width / 2,
                    startAngle: startAngle,
                    endAngle: startAngle + Angle.degrees(240),
                    clockwise: false
                )
                context.stroke(
                    track,
                    with: .color(colors.arcTrack),
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                )

                if speedPercent > 0 {
                    if !isOverLimit {
                        var arc = Path()
                        arc.addArc(
                            center: CGPoint(x: size.width / 2, y: size.height / 2),
                            radius: rect.width / 2,
                            startAngle: startAngle,
                            endAngle: startAngle + Angle.degrees(240 * speedPercent),
                            clockwise: false
                        )
                        context.stroke(
                            arc,
                            with: .linearGradient(
                                Gradient(colors: [colors.neonGreen, colors.neonBlue]),
                                startPoint: .zero,
                                endPoint: CGPoint(x: size.width, y: size.height)
                            ),
                            style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                        )
                    } else {
                        var teal = Path()
                        teal.addArc(
                            center: CGPoint(x: size.width / 2, y: size.height / 2),
                            radius: rect.width / 2,
                            startAngle: startAngle,
                            endAngle: startAngle + Angle.degrees(240 * limitPercent),
                            clockwise: false
                        )
                        context.stroke(
                            teal,
                            with: .color(colors.neonGreen.opacity(0.35)),
                            style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                        )

                        var red = Path()
                        red.addArc(
                            center: CGPoint(x: size.width / 2, y: size.height / 2),
                            radius: rect.width / 2,
                            startAngle: startAngle + Angle.degrees(240 * limitPercent),
                            endAngle: startAngle + Angle.degrees(240 * speedPercent),
                            clockwise: false
                        )
                        context.stroke(
                            red,
                            with: .color(colors.stopRed),
                            style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                        )
                    }

                    let angleRad = (150 + 240 * speedPercent) * .pi / 180
                    let radius = rect.width / 2
                    let cx = size.width / 2 + radius * cos(angleRad)
                    let cy = size.height / 2 + radius * sin(angleRad)
                    let dotColor = isOverLimit ? colors.stopRed : colors.neonGreen
                    context.fill(
                        Path(ellipseIn: CGRect(x: cx - 7, y: cy - 7, width: 14, height: 14)),
                        with: .color(dotColor)
                    )
                }
            }
            .frame(width: 260, height: 260)

            VStack(spacing: 0) {
                Text("\(Int(speedKmh))")
                    .font(.system(size: 72, weight: .bold))
                    .foregroundStyle(isOverLimit ? colors.stopRed : colors.textPrimary)
                Text("KM/H")
                    .font(.system(size: 14, weight: .medium))
                    .tracking(3)
                    .foregroundStyle(colors.textMuted)
            }

            SpeedLimitSign(
                limitKmh: Int(speedLimitKmh),
                isOverLimit: isOverLimit,
                isAutoLimit: isAutoLimit
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 8)
            .padding(.leading, 4)
            .onTapGesture {
                onCycleSpeedLimit?()
            }
            .onLongPressGesture(minimumDuration: 0.5) {
                onClearManualOverride?()
            }
            .accessibilityLabel("Speed limit \(Int(speedLimitKmh)) kilometers per hour")
            .accessibilityHint("Tap to set manually, long press to use road limit from map data")
            .accessibilityAddTraits(.isButton)
        }
        .frame(width: 260, height: 260)
        .animation(.easeInOut(duration: 0.35), value: speedKmh)
    }
}

/// European-style circular speed-limit badge. Flashes red / blue / white when over limit.
struct SpeedLimitSign: View {
    let limitKmh: Int
    let isOverLimit: Bool
    var isAutoLimit: Bool = false

    private enum FlashPhase: Int {
        case red = 0
        case blue = 1
        case white = 2
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.16, paused: !isOverLimit)) { context in
            let phase = FlashPhase(
                rawValue: Int(context.date.timeIntervalSinceReferenceDate / 0.16) % 3
            ) ?? .red
            let fill = isOverLimit ? flashFill(phase) : Color.white
            let ring = isOverLimit ? flashRing(phase) : Color(hex: 0xE30613)
            let number = isOverLimit ? flashNumber(phase) : Color.black

            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    Circle()
                        .fill(fill)
                        .shadow(color: isOverLimit ? flashFill(phase).opacity(0.55) : .black.opacity(0.25), radius: isOverLimit ? 8 : 3, y: 1)

                    Circle()
                        .stroke(ring, lineWidth: 5.5)

                    Text("\(limitKmh)")
                        .font(.system(size: limitKmh >= 100 ? 18 : 22, weight: .bold, design: .rounded))
                        .foregroundStyle(number)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
                .frame(width: 54, height: 54)

                if isAutoLimit {
                    Circle()
                        .fill(Color(hex: 0x00E5A0))
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Color.white, lineWidth: 1))
                        .offset(x: 2, y: 2)
                }
            }
        }
    }

    private func flashFill(_ phase: FlashPhase) -> Color {
        switch phase {
        case .red: Color(hex: 0xE30613)
        case .blue: Color(hex: 0x0055FF)
        case .white: .white
        }
    }

    private func flashRing(_ phase: FlashPhase) -> Color {
        switch phase {
        case .red: .white
        case .blue: .white
        case .white: Color(hex: 0xE30613)
        }
    }

    private func flashNumber(_ phase: FlashPhase) -> Color {
        switch phase {
        case .red, .blue: .white
        case .white: .black
        }
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
        VStack(spacing: 8) {
            Text(String(format: "%.2f G", value))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(colors.textPrimary)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(colors.arcTrack)
                    Capsule()
                        .fill(colors.startGradient)
                        .frame(width: max(geo.size.width * fillFraction, 0))
                    Rectangle()
                        .fill(colors.gForceTick)
                        .frame(width: 1)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 200, height: 6)

            Text(String(format: "MAX: %.2f G", maxValue))
                .font(.system(size: 11))
                .foregroundStyle(colors.textMuted)
        }
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
        HStack(spacing: 5) {
            Canvas { context, size in
                let bodyW = size.width - 3
                let bodyH = size.height
                let termH: CGFloat = 5
                context.stroke(
                    Path(roundedRect: CGRect(x: 0, y: 0, width: bodyW, height: bodyH), cornerRadius: 2),
                    with: .color(colors.batteryOutline),
                    lineWidth: 1.5
                )
                context.fill(
                    Path(roundedRect: CGRect(x: bodyW, y: (bodyH - termH) / 2, width: 3, height: termH), cornerRadius: 1),
                    with: .color(colors.batteryOutline)
                )
                let fillW = max((bodyW - 4) * CGFloat(level) / 100, 0)
                context.fill(
                    Path(roundedRect: CGRect(x: 2, y: 2, width: fillW, height: bodyH - 4), cornerRadius: 1),
                    with: .color(fillColor)
                )
            }
            .frame(width: 24, height: 13)

            Text("\(level)%")
                .font(.system(size: 11))
                .foregroundStyle(colors.batteryLabel)
        }
    }
}

enum BatteryReader {
    static func currentLevel() -> Int {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        if level < 0 { return 100 }
        return Int(level * 100)
    }
}
