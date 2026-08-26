import SwiftUI
import UIKit
import os

struct RideTrackerView: View {
    @Environment(AppContainer.self) private var app
    @Environment(ThemeStore.self) private var theme
    @State private var clock = RideFormatters.currentClock()
    @State private var batteryLevel = BatteryReader.currentLevel()
    @State private var discardBanner: String?

    private static let selectableSpeedLimits = [30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130]

    private var speedLimitKmh: Int { app.speedLimitService.effectiveLimitKmh }

    var body: some View {
        let session = app.tripManager.sessionState
        let stats = session.stats
        let colors = theme.palette
        let isOverLimit = session.isActive && !session.isPaused && stats.speed > Double(speedLimitKmh)

        ScrollView {
            VStack(spacing: 20) {
                speedometerCard(stats: stats, colors: colors)
                statsGrid(stats: stats, colors: colors)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(colors.bgDeep.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            bottomBar(session: session, colors: colors)
        }
        .overlay {
            OverLimitScreenFlash(isActive: isOverLimit)
                .allowsHitTesting(false)
                .ignoresSafeArea()
        }
        .overlay(alignment: .top) {
            if let banner = discardBanner {
                Text(banner)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(colors.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .navigationTitle("Ride")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 8) {
                    Text(clock)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(colors.textSecondary)
                    BatteryIndicator(level: batteryLevel, colors: colors)
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    theme.toggle()
                } label: {
                    Image(systemName: theme.mode.toggleSymbol)
                }
                .accessibilityLabel("Switch to \(theme.mode.toggleLabel) theme")

                NavigationLink(value: AppRoute.history) {
                    Image(systemName: "list.bullet")
                }
                .accessibilityLabel("Ride history")
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

    private func speedometerCard(stats: TripStats, colors: AppPalette) -> some View {
        VStack(spacing: 14) {
            if stats.gpsQuality != .unknown || stats.gpsAccuracyMeters != nil {
                gpsStatusRow(stats: stats, colors: colors)
            }
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
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .background(colors.bgCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func gpsStatusRow(stats: TripStats, colors: AppPalette) -> some View {
        let tint: Color = {
            switch stats.gpsQuality {
            case .good: colors.neonGreen
            case .fair: colors.routeAmber
            case .poor: colors.neonRed
            case .unknown: colors.textMuted
            }
        }()
        let title: String = {
            if let meters = stats.gpsAccuracyMeters {
                return "\(stats.gpsQuality.label) ±\(Int(meters))m"
            }
            return stats.gpsQuality.label
        }()

        return Label(title, systemImage: "location.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        let metrics: [(String, String, Color?)] = [
            ("Distance", String(format: "%.1f km", stats.distanceKm), nil),
            ("Total time", RideFormatters.secondsToTime(stats.tripTime), nil),
            ("Moving", RideFormatters.secondsToTime(stats.movingTime), colors.neonGreen),
            ("Stopped", RideFormatters.secondsToTime(stats.stoppedTime), colors.neonRed),
            ("Avg speed", "\(Int(stats.avgSpeed)) km/h", nil),
            ("Max speed", "\(Int(stats.maxSpeed)) km/h", nil),
            ("Elevation", "\(Int(stats.totalElevationGain)) m", nil),
            ("Max G", String(format: "%.2f G", stats.maxGForce), colors.neonBlue),
            ("Lateral G", String(format: "%.2f G", stats.currentLateralGForce), colors.neonBlue),
            ("Corners", "\(stats.cornerCount)", colors.neonGreen)
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

    private func bottomBar(session: RideSessionState, colors: AppPalette) -> some View {
        HStack(spacing: 12) {
            if session.isActive {
                Button {
                    if session.isPaused {
                        app.resumeRide()
                    } else {
                        app.pauseRide()
                    }
                } label: {
                    Label(
                        session.isPaused ? "Resume" : "Pause",
                        systemImage: session.isPaused ? "play.fill" : "pause.fill"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                }
                .buttonStyle(.bordered)
                .tint(colors.textPrimary)

                Button(role: .destructive) {
                    let saved = app.stopRide()
                    UIApplication.shared.isIdleTimerDisabled = false
                    if !saved {
                        withAnimation {
                            discardBanner = "Ride too short — not saved"
                        }
                        Task {
                            try? await Task.sleep(for: .seconds(2.5))
                            withAnimation { discardBanner = nil }
                        }
                    }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(colors.stopRed)
            } else {
                let enabled = app.locationService.isLocationEnabled
                Button {
                    app.startRide()
                } label: {
                    Text(enabled ? "Start Ride" : "Enable GPS to Start")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(colors.neonGreen)
                .disabled(!enabled)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }
}

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
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundStyle(isOverLimit ? colors.stopRed : colors.textPrimary)
                Text("km/h")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(colors.textSecondary)
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
    var isAutoLimit: Bool = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.16, paused: !isOverLimit)) { context in
            let phase = OverLimitFlashPhase.current(at: context.date)
            let fill = isOverLimit ? phase.fill : Color.white
            let ring = isOverLimit ? phase.ring : Color(hex: 0xE30613)
            let number = isOverLimit ? phase.number : Color.black

            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    Circle()
                        .fill(fill)
                        .shadow(color: isOverLimit ? phase.fill.opacity(0.55) : .black.opacity(0.25), radius: isOverLimit ? 8 : 3, y: 1)

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
                .font(.caption2)
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
        return Int(level * 100)
    }
}
