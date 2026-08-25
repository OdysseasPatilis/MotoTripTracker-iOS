import SwiftUI

struct RideHistoryView: View {
    @Environment(AppContainer.self) private var app
    @Environment(ThemeStore.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var rides: [Trip] = []

    var body: some View {
        let colors = theme.palette

        ZStack {
            colors.bgDeep.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                ScreenTopBar(title: "Ride History", onBack: { dismiss() })

                Text("RECENT RIDES")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(2)
                    .foregroundStyle(colors.textMuted)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                if rides.isEmpty {
                    Spacer()
                    Text("No rides recorded yet")
                        .font(.system(size: 14))
                        .foregroundStyle(colors.emptyText)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(rides, id: \.id) { ride in
                                NavigationLink(value: AppRoute.summary(ride.id)) {
                                    RideHistoryCard(ride: ride, colors: colors)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            rides = app.repository.allTrips()
        }
    }
}

struct RideHistoryCard: View {
    let ride: Trip
    let colors: AppPalette

    var body: some View {
        ZStack(alignment: .leading) {
            colors.bgCard

            // Compose-style left accent (4pt × ~82pt)
            colors.startGradient
                .frame(width: 4, height: 82)
                .frame(maxHeight: .infinity, alignment: .center)

            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(colors.bgSurface)
                        .frame(width: 36, height: 36)
                    Image(systemName: "bicycle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(colors.neonGreen)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(RideFormatters.timestampToDate(ride.startTime))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(colors.neonGreen)
                    Text("\(RideFormatters.secondsToTime(ride.totalTime)) duration")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(colors.textPrimary)
                    Text(
                        String(
                            format: "%.1f km  ·  %d km/h avg",
                            ride.distanceKm,
                            Int(ride.avgSpeed)
                        )
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(colors.textMuted)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(colors.emptyText)
            }
            .padding(.leading, 16)
            .padding(.trailing, 16)
            .padding(.vertical, 16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(colors.borderSubtle, lineWidth: 1)
        )
    }
}
