import CoreLocation
import SwiftUI
import UIKit
import os

struct RideTrackerView: View {
    @Environment(AppContainer.self) private var app
    @Environment(ThemeStore.self) private var theme
    @Environment(\.appNavigate) private var navigate
    @Environment(\.scenePhase) private var scenePhase
    @State private var batteryLevel = BatteryReader.currentLevel()
    @State private var discardBanner: String?
    @State private var showDestinationSearch = false
    @State private var showFuelSettings = false
    @State private var showPetrolPicker = false
    @State private var showRouteWeather = false

    private var speedLimitKmh: Int { app.speedLimitService.effectiveLimitKmh }

    /// Prefer live Core Location accuracy so the toolbar updates even when idle.
    private var dashboardGpsAccuracy: Double? {
        let accuracy = app.locationService.lastLocation?.horizontalAccuracy
        guard let accuracy, accuracy >= 0 else {
            return app.tripManager.sessionState.stats.gpsAccuracyMeters
        }
        return accuracy
    }

    private var dashboardGpsQuality: GpsQuality {
        GpsQuality.fromAccuracyMeters(dashboardGpsAccuracy)
    }

    var body: some View {
        let session = app.tripManager.sessionState
        let stats = session.stats
        let colors = theme.palette
        let isOverLimit = session.isActive && !session.isPaused && stats.speed > Double(speedLimitKmh)
        // While actively riding the map rotates and shows its compass at the top-right,
        // so the Options menu (same corner) is hidden to avoid overlap.
        let isRiding = session.isActive && !session.isPaused

        GeometryReader { geo in
            VStack(spacing: 0) {
                LiveRideMapView()
                    .frame(height: geo.size.height * 0.46)
                    .overlay(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 8) {
                                topLeftHUD(colors: colors)
                                Spacer(minLength: 0)
                                if session.isActive, !app.locationService.hasAlwaysAuthorization {
                                    alwaysLocationIconButton(colors: colors)
                                }
                                if !isRiding {
                                    optionsMenu(colors: colors)
                                }
                            }
                            if app.navigationService.hasDestination {
                                topTurnBanner(colors: colors)
                                    .padding(.horizontal, 10)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .overlay(alignment: .bottom) {
                        Group {
                            if app.navigationService.hasDestination {
                                activeRouteChip(colors: colors)
                            } else {
                                VStack(spacing: 8) {
                                    if session.isActive, !app.locationService.hasAlwaysAuthorization {
                                        alwaysLocationBanner(colors: colors)
                                    }
                                    idleNavOverlay(colors: colors)
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                    }
                    .clipped()

                ScrollView {
                    VStack(spacing: 20) {
                        speedometerCard(stats: stats, colors: colors)
                        statsGrid(stats: stats, colors: colors)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
                .background(colors.bgDeep)
            }
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
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showDestinationSearch) {
            DestinationSearchView()
        }
        .sheet(isPresented: $showFuelSettings) {
            FuelSettingsView()
        }
        .sheet(isPresented: $showPetrolPicker) {
            PetrolStationsView()
        }
        .sheet(isPresented: $showRouteWeather) {
            RouteWeatherView()
        }
        .onAppear {
            batteryLevel = BatteryReader.currentLevel()
            app.locationService.requestAuthorization()
            app.locationService.refreshLocationEnabled()
            app.locationService.startUpdating()
            UIApplication.shared.isIdleTimerDisabled = true
            if let location = app.locationService.lastLocation {
                app.speedLimitService.refresh(for: location)
            }
        }
        .onDisappear {
            if !session.isActive {
                app.locationService.stopUpdating()
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                app.resumeBackgroundTrackingIfNeeded()
                UIApplication.shared.isIdleTimerDisabled = session.isActive
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
            batteryLevel = BatteryReader.currentLevel()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            batteryLevel = BatteryReader.currentLevel()
        }
    }

    private func alwaysLocationIconButton(colors: AppPalette) -> some View {
        Button {
            app.locationService.requestAlwaysForRideRecording()
            if app.locationService.authorizationStatus == .authorizedWhenInUse {
                app.locationService.openSystemLocationSettings()
            }
        } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(colors.routeAmber)
                .frame(width: 42, height: 42)
                .background(.ultraThinMaterial, in: Circle())
        }
        .padding(.trailing, 12)
        .padding(.top, 12)
        .accessibilityLabel("Allow Always Location")
    }

    private func alwaysLocationBanner(colors: AppPalette) -> some View {
        Button {
            app.locationService.requestAlwaysForRideRecording()
            // If the system already asked once, only Settings can upgrade.
            if app.locationService.authorizationStatus == .authorizedWhenInUse {
                app.locationService.openSystemLocationSettings()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(colors.routeAmber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow Always Location")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(colors.textPrimary)
                    Text("Recording stops when the screen locks without Always access. Tap to open Settings.")
                        .font(.caption2)
                        .foregroundStyle(colors.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(colors.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func topLeftHUD(colors: AppPalette) -> some View {
        HStack(spacing: 10) {
            GpsSignalIndicator(
                quality: dashboardGpsQuality,
                accuracyMeters: dashboardGpsAccuracy,
                colors: colors
            )
            BatteryIndicator(level: batteryLevel, colors: colors)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.leading, 12)
        .padding(.top, 12)
    }

    private func optionsMenu(colors: AppPalette) -> some View {
        Menu {
            Button {
                navigate(.history)
            } label: {
                Label("Ride History", systemImage: "list.bullet")
            }
            Button {
                navigate(.leaderboard)
            } label: {
                Label("Leaderboard", systemImage: "trophy")
            }
            Divider()
            Button {
                showFuelSettings = true
            } label: {
                Label("Fuel & Range", systemImage: "fuelpump")
            }
            Button {
                showPetrolPicker = true
            } label: {
                Label("Nearest Petrol", systemImage: "mappin.and.ellipse")
            }
            Divider()
            Button {
                theme.toggle()
            } label: {
                Label("\(theme.mode.toggleLabel) Mode", systemImage: theme.mode.toggleSymbol)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.headline.weight(.bold))
                .foregroundStyle(colors.textPrimary)
                .frame(width: 42, height: 42)
                .background(.ultraThinMaterial, in: Circle())
        }
        .padding(.trailing, 12)
        .padding(.top, 12)
        .accessibilityLabel("Options")
    }

    @ViewBuilder
    private func idleNavOverlay(colors: AppPalette) -> some View {
        let fuel = app.fuelService
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    showDestinationSearch = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                        Text("Set destination")
                        Spacer(minLength: 0)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(colors.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
                }

                Button {
                    showPetrolPicker = true
                } label: {
                    Image(systemName: "fuelpump.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(fuel.isLowFuel ? colors.neonRed : colors.neonGreen)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Nearest petrol")
            }

            HStack(spacing: 6) {
                Image(systemName: "gauge.with.needle")
                    .font(.caption2)
                Text(fuel.rangeSummary)
                    .font(.caption.weight(.semibold))
                if fuel.isLowFuel {
                    Text("· Low")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(colors.neonRed)
                }
            }
            .foregroundStyle(fuel.isLowFuel ? colors.neonRed : colors.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 2)
    }

    private func topTurnBanner(colors: AppPalette) -> some View {
        let nav = app.navigationService
        let accent = (nav.isOffRoute || nav.isRecalculating) ? colors.routeAmber : colors.neonBlue
        return HStack(spacing: 12) {
            Image(systemName: maneuverSymbol(for: nav))
                .font(.title2.weight(.bold))
                .foregroundStyle(colors.bgDeep)
                .frame(width: 44, height: 44)
                .background(accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                if nav.isRecalculating {
                    Text("Recalculating…")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(colors.textPrimary)
                } else if nav.isOffRoute {
                    Text("Off route")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(colors.textPrimary)
                } else if let step = nav.currentStep {
                    Text(NavigationService.formatDistance(nav.distanceToNextManeuver))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(colors.textPrimary)
                    Text(step.instruction)
                        .font(.caption)
                        .foregroundStyle(colors.textSecondary)
                        .lineLimit(1)
                } else if nav.isRouting {
                    Text("Calculating route…")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(colors.textPrimary)
                } else {
                    Text(nav.destinationName ?? "Destination")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(colors.textPrimary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func activeRouteChip(colors: AppPalette) -> some View {
        let nav = app.navigationService
        @Bindable var weather = app.routeWeatherService
        return HStack(spacing: 10) {
            Text(nav.isRouting ? "Routing…" : nav.summaryText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(colors.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if nav.hasRoute, !nav.isRouting {
                Button {
                    showRouteWeather = true
                } label: {
                    Group {
                        if weather.isLoading {
                            ProgressView()
                                .controlSize(.mini)
                        } else if let first = weather.segments.first {
                            Image(systemName: first.conditionSymbol)
                        } else {
                            Image(systemName: "cloud.fill")
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(weather.lastError != nil ? colors.routeAmber : colors.neonBlue)
                    .frame(width: 28, height: 28)
                }
                .accessibilityLabel("Route weather")
            }

            Button {
                nav.toggleVoice()
            } label: {
                Image(systemName: nav.isVoiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(nav.isVoiceEnabled ? colors.neonGreen : colors.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel(nav.isVoiceEnabled ? "Mute voice guidance" : "Enable voice guidance")

            Button {
                nav.openInAppleMaps()
            } label: {
                Image(systemName: "location.north.line.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(colors.neonGreen)
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("Open in Apple Maps")

            Button {
                nav.clear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(colors.textSecondary)
            }
            .accessibilityLabel("Clear destination")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 2)
    }

    private func maneuverSymbol(for nav: NavigationService) -> String {
        if nav.isRecalculating || nav.isOffRoute {
            return "arrow.triangle.2.circlepath"
        }
        let text = (nav.currentStep?.instruction ?? "").lowercased()
        if text.contains("u-turn") || text.contains("u turn") { return "arrow.uturn.left" }
        if text.contains("roundabout") || text.contains("rotary") { return "arrow.triangle.2.circlepath" }
        if text.contains("keep left") || text.contains("bear left") { return "arrow.up.left" }
        if text.contains("keep right") || text.contains("bear right") { return "arrow.up.right" }
        if text.contains("left") { return "arrow.turn.up.left" }
        if text.contains("right") { return "arrow.turn.up.right" }
        if text.contains("destination") || text.contains("arrive") { return "flag.checkered" }
        if text.contains("straight") || text.contains("continue") { return "arrow.up" }
        return "arrow.triangle.turn.up.right.diamond.fill"
    }

    private func speedometerCard(stats: TripStats, colors: AppPalette) -> some View {
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

    private func statsGrid(stats: TripStats, colors: AppPalette) -> some View {
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
            ("Twistiness", twistinessLabel(stats), colors.neonBlue)
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

    private func twistinessLabel(_ stats: TripStats) -> String {
        let score = TwistinessCalculator.score(
            cornerCount: stats.cornerCount,
            distanceKm: stats.distanceKm,
            maxLateralGForce: stats.maxLateralGForce
        )
        guard score > 0 else { return "—" }
        return TwistinessCalculator.formattedScore(score)
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
