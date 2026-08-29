import SwiftUI

/// Timeline of weather samples along the planned route.
struct RouteWeatherView: View {
    @Environment(AppContainer.self) private var app
    @Environment(ThemeStore.self) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var weather = app.routeWeatherService
        let colors = theme.palette

        NavigationStack {
            Group {
                if weather.isLoading, weather.segments.isEmpty {
                    ProgressView("Loading route weather…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if weather.segments.isEmpty {
                    ContentUnavailableView(
                        "No weather data",
                        systemImage: "cloud",
                        description: Text("Set a destination to see forecast conditions along your route.")
                    )
                } else {
                    List {
                        if weather.hasRainAlongRoute {
                            Section {
                                Label("Rain likely along your route", systemImage: "cloud.rain.fill")
                                    .foregroundStyle(colors.neonBlue)
                                    .font(.subheadline.weight(.medium))
                            }
                        }

                        Section {
                            ForEach(weather.segments) { segment in
                                HStack(spacing: 14) {
                                    Image(systemName: segment.conditionSymbol)
                                        .font(.title2)
                                        .foregroundStyle(colors.neonBlue)
                                        .frame(width: 32)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(segment.label)
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(colors.textPrimary)
                                        Text(segment.eta.formatted(date: .omitted, time: .shortened))
                                            .font(.caption)
                                            .foregroundStyle(colors.textSecondary)
                                    }

                                    Spacer()

                                    VStack(alignment: .trailing, spacing: 4) {
                                        if let temp = segment.temperatureC {
                                            Text("\(Int(temp.rounded()))°")
                                                .font(.body.weight(.bold))
                                                .foregroundStyle(colors.textPrimary)
                                        }
                                        if let rain = segment.precipitationProbability, rain > 0 {
                                            Text("\(rain)% rain")
                                                .font(.caption2.weight(.medium))
                                                .foregroundStyle(rain >= 40 ? colors.neonBlue : colors.textSecondary)
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                                .listRowBackground(colors.bgCard)
                            }
                        } header: {
                            Text("Along your route")
                        } footer: {
                            Text("Forecasts are sampled along your planned route at estimated arrival times.")
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(colors.bgDeep.ignoresSafeArea())
            .navigationTitle("Route Weather")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .tint(colors.neonGreen)
                }
            }
        }
    }
}
