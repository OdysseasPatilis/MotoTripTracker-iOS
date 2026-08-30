import CoreLocation
import SwiftUI
import UIKit
import os

struct RideTrackerView: View {
    @Environment(AppContainer.self) private var app
    @Environment(ThemeStore.self) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @State private var batteryLevel = BatteryReader.currentLevel()
    @State private var discardBanner: String?
    @State private var showDestinationSearch = false
    @State private var showFuelSettings = false
    @State private var showPetrolPicker = false
    @State private var showRouteWeather = false

    private static let selectableSpeedLimits = [30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130]

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
                    .overlay(alignment: .topLeading) {
                        topLeftHUD(colors: colors)
                    }
                    .overlay(alignment: .topTrailing) {
                        if !isRiding {
                            optionsMenu(colors: colors)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        VStack(spacing: 8) {
                            if session.isActive, !app.locationService.hasAlwaysAuthorization {
                                alwaysLocationBanner(colors: colors)
                            }
                            navOverlay(colors: colors)
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
            NavigationLink(value: AppRoute.history) {
                Label("Ride History", systemImage: "list.bullet")
            }
            NavigationLink(value: AppRoute.leaderboard) {
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
    private func navOverlay(colors: AppPalette) -> some View {
        let nav = app.navigationService
        let fuel = app.fuelService
        VStack(spacing: 8) {
            if nav.hasDestination {
                if nav.currentStep != nil || nav.isRecalculating || nav.isOffRoute {
                    maneuverBanner(nav: nav, colors: colors)
                }
                activeRouteBanner(nav: nav, colors: colors)
            } else {
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
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func maneuverBanner(nav: NavigationService, colors: AppPalette) -> some View {
        let accent = (nav.isOffRoute || nav.isRecalculating) ? colors.routeAmber : colors.neonBlue
        return HStack(spacing: 12) {
            Image(systemName: maneuverSymbol(for: nav))
                .font(.title2.weight(.bold))
                .foregroundStyle(colors.bgDeep)
                .frame(width: 48, height: 48)
                .background(accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                if nav.isRecalculating {
                    Text("Recalculating route…")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(colors.textPrimary)
                    Text("Finding a better path")
                        .font(.caption)
                        .foregroundStyle(colors.textSecondary)
                } else if nav.isOffRoute {
                    Text("Off route")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(colors.textPrimary)
                    Text("Hold on — recalculating")
                        .font(.caption)
                        .foregroundStyle(colors.textSecondary)
                } else if let step = nav.currentStep {
                    Text(NavigationService.formatDistance(nav.distanceToNextManeuver))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(colors.textPrimary)
                    Text(step.instruction)
                        .font(.caption)
                        .foregroundStyle(colors.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func activeRouteBanner(nav: NavigationService, colors: AppPalette) -> some View {
        @Bindable var weather = app.routeWeatherService
        return VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "flag.checkered")
                    .font(.title3)
                    .foregroundStyle(colors.neonBlue)

                VStack(alignment: .leading, spacing: 2) {
                    Text(nav.destinationName ?? "Destination")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(colors.textPrimary)
                        .lineLimit(1)
                    Text(nav.isRouting ? "Calculating route…" : nav.summaryText)
                        .font(.caption)
                        .foregroundStyle(colors.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button {
                    nav.openInAppleMaps()
                } label: {
                    Image(systemName: "location.north.line.fill")
                        .font(.headline)
                        .foregroundStyle(colors.neonGreen)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("Open in Apple Maps")

                Button {
                    nav.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(colors.textSecondary)
                }
                .accessibilityLabel("Clear destination")
            }

            if nav.hasRoute, !nav.isRouting {
                Button {
                    showRouteWeather = true
                } label: {
                    HStack(spacing: 8) {
                        if weather.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else if let first = weather.segments.first {
                            Image(systemName: first.conditionSymbol)
                                .foregroundStyle(colors.neonBlue)
                        } else {
                            Image(systemName: "cloud.fill")
                                .foregroundStyle(weather.lastError != nil ? colors.routeAmber : colors.neonBlue)
                        }
                        Text(weather.summaryText)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(
                                weather.lastError != nil ? colors.routeAmber : colors.textSecondary
                            )
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(colors.textSecondary.opacity(0.7))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
    var isAutoLimit: Bool = false
    var onCycleSpeedLimit: (() -> Void)?
    var onClearManualOverride: (() -> Void)?

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
                    isOverLimit: isOverLimit,
                    isAutoLimit: isAutoLimit
                )
                .onTapGesture {
                    onCycleSpeedLimit?()
                }
                .onLongPressGesture(minimumDuration: 0.5) {
                    onClearManualOverride?()
                }
                .accessibilityLabel("Speed limit \(Int(speedLimitKmh)) kilometers per hour")
                .accessibilityHint("Tap to set manually, long press to use road limit from map data")
                .accessibilityAddTraits(.isButton)

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
