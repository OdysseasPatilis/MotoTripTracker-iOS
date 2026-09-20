import CoreLocation
import SwiftUI

struct RideMapTopOverlay: View {
    @Environment(AppContainer.self) private var app
    @Environment(ThemeStore.self) private var theme
    @Environment(\.appNavigate) private var navigate

    let session: RideSessionState
    let isRiding: Bool
    let batteryLevel: Int
    let gpsQuality: GpsQuality
    let gpsAccuracy: Double?
    let colors: AppPalette
    @Binding var showFuelSettings: Bool
    @Binding var showBackendSettings: Bool
    @Binding var showPetrolPicker: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                topLeftHUD
                Spacer(minLength: 0)
                if session.isActive, !app.locationService.hasAlwaysAuthorization {
                    alwaysLocationIconButton
                }
                if !isRiding {
                    optionsMenu
                }
            }
            if app.navigationService.isNavigating {
                topTurnBanner
                    .padding(.horizontal, 10)
            }
            if let alert = app.trafficCameraService.activeAlert {
                trafficCameraBanner(alert)
                    .padding(.horizontal, 10)
            }
            switch app.trafficCameraService.downloadStatus {
            case .idle:
                EmptyView()
            case let .downloading(code, name):
                Text("Downloading cameras for \(name ?? code)…")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(colors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 10)
            case let .failed(message):
                Text(message)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(colors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 10)
            }
        }
        .padding(.top, 4)
    }

    private var topLeftHUD: some View {
        HStack(spacing: 10) {
            GpsSignalIndicator(
                quality: gpsQuality,
                accuracyMeters: gpsAccuracy,
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

    private var alwaysLocationIconButton: some View {
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

    private var optionsMenu: some View {
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
                showBackendSettings = true
            } label: {
                Label("Cloud Sync", systemImage: "icloud.and.arrow.up")
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

    private var topTurnBanner: some View {
        let nav = app.navigationService
        let accent = (nav.isOffRoute || nav.isRecalculating) ? colors.routeAmber : colors.neonBlue
        return HStack(spacing: 14) {
            Image(systemName: maneuverSymbol(for: nav))
                .font(.title.weight(.bold))
                .foregroundStyle(colors.bgDeep)
                .frame(width: 56, height: 56)
                .background(accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                if nav.isRecalculating {
                    Text("Recalculating…")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(colors.textPrimary)
                } else if nav.isOffRoute {
                    Text("Off route")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(colors.textPrimary)
                } else if let step = nav.currentStep {
                    Text(NavigationService.formatDistance(nav.distanceToNextManeuver))
                        .font(.title.weight(.bold))
                        .foregroundStyle(colors.textPrimary)
                    Text(step.instruction)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(colors.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if nav.isRouting {
                    Text("Calculating route…")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(colors.textPrimary)
                } else {
                    Text(nav.destinationName ?? "Destination")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(colors.textPrimary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func trafficCameraBanner(_ alert: TrafficCameraAlert) -> some View {
        HStack(spacing: 10) {
            Image(systemName: alert.camera.kind == .speed ? "camera.fill" : "trafficlight.fill")
                .foregroundStyle(colors.routeAmber)
            Text(alert.bannerText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel(alert.bannerText)
    }
}

struct RideMapBottomOverlay: View {
    @Environment(AppContainer.self) private var app

    let session: RideSessionState
    let colors: AppPalette
    @Binding var showDestinationSearch: Bool
    @Binding var showPetrolPicker: Bool
    @Binding var showRouteWeather: Bool
    @Binding var timingBanner: String?

    var body: some View {
        Group {
            switch app.navigationService.phase {
            case .idle:
                VStack(spacing: 8) {
                    if let timingBanner {
                        timingResultBanner(timingBanner)
                    }
                    if session.isActive, !app.locationService.hasAlwaysAuthorization {
                        alwaysLocationBanner
                    }
                    idleNavOverlay
                }
            case .previewing:
                routePreviewCard
            case .navigating:
                VStack(spacing: 6) {
                    if let hint = app.navigationService.trafficHintText {
                        Text(hint)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(colors.routeAmber)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    activeRouteChip
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var alwaysLocationBanner: some View {
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

    @ViewBuilder
    private var idleNavOverlay: some View {
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

    private func timingResultBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "flag.checkered")
                .foregroundStyle(colors.neonGreen)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                withAnimation {
                    timingBanner = nil
                    app.navigationService.dismissTimingResult()
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(colors.textSecondary)
            }
            .accessibilityLabel("Dismiss timing summary")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var activeRouteChip: some View {
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

    private var routePreviewCard: some View {
        let nav = app.navigationService
        let canStart = nav.selectedRouteID != nil
            && !nav.isRouting
            && nav.previewErrorMessage == nil

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "flag.checkered")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(colors.neonBlue)
                Text(nav.destinationName ?? "Destination")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(colors.textPrimary)
                    .lineLimit(1)
            }

            if nav.isRouting {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(colors.neonBlue)
                    Text("Finding routes…")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(colors.textSecondary)
                }
            } else if let errorMessage = nav.previewErrorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(colors.routeAmber)
            } else {
                HStack(spacing: 8) {
                    ForEach(Array(nav.previewRoutes.enumerated()), id: \.element.id) { index, option in
                        let isSelected = option.id == nav.selectedRouteID
                        Button {
                            nav.selectPreviewRoute(id: option.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(index == 0 ? "Fastest" : "Route \(index + 1)")
                                    .font(.caption.weight(.bold))
                                Text(
                                    "\(NavigationService.formatDistance(option.distanceMeters)) · Moto \(MotoTravelEstimator.formatMinutes(option.motoTravelTime))"
                                )
                                .font(.caption2.weight(.medium))
                                if option.trafficDelay >= 90 {
                                    Text("Cars \(MotoTravelEstimator.formatMinutes(option.expectedTravelTime))")
                                        .font(.caption2)
                                        .foregroundStyle(isSelected ? colors.routeAmber : colors.textMuted)
                                }
                            }
                            .foregroundStyle(isSelected ? colors.textPrimary : colors.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                isSelected ? colors.neonBlue.opacity(0.18) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(
                                        isSelected ? colors.neonGreen : colors.textMuted.opacity(0.35),
                                        lineWidth: isSelected ? 1.5 : 1
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    nav.cancelPreview()
                } label: {
                    Text("Cancel")
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .tint(colors.textSecondary)

                Button {
                    nav.confirmStartNavigation()
                } label: {
                    Text("Start")
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(colors.neonGreen)
                .disabled(!canStart)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 2)
    }
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
