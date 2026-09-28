import SwiftUI

struct RideControlsBar: View {
    @Environment(AppContainer.self) private var app
    let session: RideSessionState
    let colors: AppPalette
    @Binding var discardBanner: String?

    var body: some View {
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
        .padding(.top, 0)
        .padding(.bottom, 8)
        .background(.bar)
    }
}

/// Slim Dist / Avg / ETA strip plus compact ride controls, used only while guiding.
struct NavigationGlanceBar: View {
    @Environment(AppContainer.self) private var app
    let session: RideSessionState
    @Binding var discardBanner: String?

    private var stats: TripStats { session.stats }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                metric(icon: "motorcycle", title: "Dist", value: distanceText)
                hairline
                metric(icon: "gauge.with.dots.needle.33percent", title: "Avg", value: averageText)
                hairline
                metric(icon: "clock", title: "ETA", value: etaText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            rideButtons
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.top, 7)
        .padding(.bottom, 6)
        .background(NavigationHUDChrome.scrim.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(NavigationHUDChrome.hairline)
                .frame(height: 0.5)
        }
    }

    private var distanceText: String {
        let kilometers = session.isActive ? stats.distanceKm : 0
        return String(format: "%.1f km", kilometers)
    }

    private var averageText: String {
        guard session.isActive, stats.avgSpeed >= 1 || stats.distanceMeters >= 100 else { return "--" }
        return "\(Int(stats.avgSpeed.rounded()))"
    }

    private var etaText: String {
        NavigationCueFormatting.remainingTimeLabel(until: app.navigationService.eta)
    }

    private func metric(icon: String, title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(NavigationHUDChrome.label)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(NavigationHUDChrome.value)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var hairline: some View {
        Rectangle()
            .fill(NavigationHUDChrome.hairline)
            .frame(width: 1, height: 26)
    }

    @ViewBuilder
    private var rideButtons: some View {
        if session.isActive {
            compactButton(
                title: session.isPaused ? "Resume" : "Pause",
                fill: NavigationHUDChrome.pauseFill,
                foreground: NavigationHUDChrome.value
            ) {
                if session.isPaused {
                    app.resumeRide()
                } else {
                    app.pauseRide()
                }
            }
            .accessibilityLabel(session.isPaused ? "Resume ride" : "Pause ride")

            compactButton(title: "Stop", fill: NavigationHUDChrome.stopFill, foreground: .white) {
                stopRide()
            }
            .accessibilityLabel("Stop ride")
        } else {
            let enabled = app.locationService.isLocationEnabled
            compactButton(
                title: enabled ? "Start" : "GPS",
                fill: NavigationHUDChrome.startFill,
                foreground: Color(hex: 0x06281F)
            ) {
                app.startRide()
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
            .accessibilityLabel(enabled ? "Start ride" : "Enable GPS to start")
        }
    }

    private func compactButton(
        title: String,
        fill: Color,
        foreground: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minWidth: 72, minHeight: 38)
                .padding(.horizontal, 8)
                .background(fill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func stopRide() {
        let saved = app.stopRide()
        if !saved {
            withAnimation {
                discardBanner = "Ride too short — not saved"
            }
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                withAnimation { discardBanner = nil }
            }
        }
    }
}
