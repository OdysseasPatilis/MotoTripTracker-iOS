import CoreLocation
import SwiftData
import SwiftUI
import UIKit

struct RideTrackerView: View {
    @Environment(AppContainer.self) private var app
    @Environment(ThemeStore.self) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @State private var batteryLevel = BatteryReader.currentLevel()
    @State private var discardBanner: String?
    @State private var showDestinationSearch = false
    @State private var showFuelSettings = false
    @State private var showBackendSettings = false
    @State private var showPetrolPicker = false
    @State private var showRouteWeather = false
    @State private var timingBanner: String?
    @State private var mapPlaceCardVisible = false

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

    /// Smoothed trip speed while recording. Before Start the trip speed stays at 0,
    /// so the dial uses the live GPS speed.
    private func displayedSpeedKmh(riding: Bool, recorded: Double) -> Double {
        if riding { return recorded }
        guard let location = app.locationService.lastLocation else { return 0 }
        return SpeedFilter().processedSpeed(from: location) * 3.6
    }

    var body: some View {
        let session = app.tripManager.sessionState
        let stats = session.stats
        let colors = theme.palette
        let riding = session.isActive && !session.isPaused
        // Sign / dial warn as soon as you exceed the limit; full-screen flash only at +10 km/h.
        let shouldFlashScreen = riding
            && stats.speed >= Double(speedLimitKmh + OverLimitScreenFlash.screenFlashToleranceKmh)
        // While actively riding the map rotates and shows its compass at the top-right,
        // so the Options menu (same corner) is hidden to avoid overlap.
        let isRiding = riding

        let navigating = app.navigationService.isNavigating
        let showsMainDial = app.navigationService.phase == .idle && !mapPlaceCardVisible
        let speedKmh = displayedSpeedKmh(riding: riding, recorded: stats.speed)

        GeometryReader { _ in
            LiveRideMapView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    RideMapTopOverlay(
                        session: session,
                        isRiding: isRiding,
                        batteryLevel: batteryLevel,
                        gpsQuality: dashboardGpsQuality,
                        gpsAccuracy: dashboardGpsAccuracy,
                        colors: colors,
                        showFuelSettings: $showFuelSettings,
                        showBackendSettings: $showBackendSettings,
                        showPetrolPicker: $showPetrolPicker,
                        showRouteWeather: $showRouteWeather
                    )
                }
                .overlay(alignment: .bottom) {
                    if !navigating {
                        VStack(spacing: 4) {
                            if showsMainDial {
                                ScrollView {
                                    VStack(spacing: 12) {
                                        SpeedometerArc(
                                            speedKmh: speedKmh,
                                            maxSpeedKmh: max(stats.maxSpeed, 260),
                                            speedLimitKmh: Double(speedLimitKmh),
                                            colors: colors
                                        )
                                        .background {
                                            Color.clear
                                                .frame(width: 228, height: 228)
                                                .glassEffect(.regular, in: .circle)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .accessibilityElement(children: .combine)

                                        VStack(spacing: 14) {
                                            GForceBar(
                                                value: stats.currentGForce,
                                                maxValue: max(stats.maxGForce, 0.01),
                                                colors: colors
                                            )
                                            RideStatsGrid(stats: stats, colors: colors)
                                        }
                                        .padding(16)
                                        .frame(maxWidth: .infinity)
                                        .glassEffect(.regular, in: .rect(cornerRadius: 20))
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.bottom, 8)
                                }
                                .frame(height: 260)
                                .contentMargins(.vertical, 0, for: .scrollContent)
                                .scrollIndicators(.hidden)
                                .clipped()
                            }
                            RideMapBottomOverlay(
                                session: session,
                                colors: colors,
                                showDestinationSearch: $showDestinationSearch,
                                showPetrolPicker: $showPetrolPicker,
                                timingBanner: $timingBanner
                            )
                        }
                    }
                }
                .clipped()
            .animation(.easeInOut(duration: 0.28), value: navigating)
            .animation(.easeInOut(duration: 0.28), value: showsMainDial)
        }
        .background(colors.bgDeep.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if navigating {
                NavigationGlanceBar(
                    session: session,
                    discardBanner: $discardBanner
                )
            } else {
                RideControlsBar(
                    session: session,
                    colors: colors,
                    discardBanner: $discardBanner
                )
            }
        }
        .overlay {
            OverLimitScreenFlash(isActive: shouldFlashScreen)
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
        .sheet(isPresented: $showBackendSettings) {
            BackendSettingsView()
        }
        .sheet(isPresented: $showPetrolPicker) {
            PetrolStationsView()
        }
        .sheet(isPresented: $showRouteWeather) {
            RouteWeatherView()
        }
        .onAppear {
            batteryLevel = BatteryReader.currentLevel()
            app.locationService.requestWhenInUseIfNeeded()
            app.locationService.refreshLocationEnabled()
            app.locationService.startUpdating()
            app.syncKeepScreenAwake()
            if let location = app.locationService.lastLocation {
                app.speedLimitService.refresh(for: location)
            }
        }
        .onPreferenceChange(MapPlaceCardVisibleKey.self) { mapPlaceCardVisible = $0 }
        .onDisappear {
            if !session.isActive {
                app.locationService.stopUpdating()
                app.syncKeepScreenAwake()
            }
        }
        .onChange(of: session.isActive) { _, _ in
            app.syncKeepScreenAwake()
        }
        .onChange(of: app.navigationService.lastTimingResult) { _, result in
            guard let result else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                timingBanner = result.summaryLine
            }
            Task {
                try? await Task.sleep(for: .seconds(8))
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        if timingBanner == result.summaryLine {
                            timingBanner = nil
                            app.navigationService.dismissTimingResult()
                        }
                    }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                app.resumeBackgroundTrackingIfNeeded()
                app.syncKeepScreenAwake()
            case .background, .inactive:
                app.prepareForBackgroundDuringRide()
            @unknown default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
            batteryLevel = BatteryReader.currentLevel()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            batteryLevel = BatteryReader.currentLevel()
        }
    }
}

#Preview {
    let app = AppContainer(inMemory: true)
    NavigationStack {
        RideTrackerView()
    }
    .environment(app)
    .environment(app.theme)
    .modelContainer(app.modelContainer)
}
