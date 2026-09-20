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
