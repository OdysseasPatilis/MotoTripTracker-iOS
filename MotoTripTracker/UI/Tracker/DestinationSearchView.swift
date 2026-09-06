import MapKit
import SwiftUI

/// Destination search sheet. Uses `MKLocalSearchCompleter` (via `NavigationService`)
/// for autocomplete; selecting a result resolves it to a coordinate, computes a
/// driving route, and dismisses.
struct DestinationSearchView: View {
    @Environment(AppContainer.self) private var app
    @Environment(ThemeStore.self) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var history: [DestinationHistoryEntry] = []

    var body: some View {
        let colors = theme.palette
        let results = app.navigationService.searchResults

        NavigationStack {
            List {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if history.isEmpty {
                        Section {
                            Text("Search for an address or place to set as your destination.")
                                .font(.subheadline)
                                .foregroundStyle(colors.textSecondary)
                                .listRowBackground(Color.clear)
                        }
                    } else {
                        Section("Recent") {
                            ForEach(history) { entry in
                                Button {
                                    app.navigationService.beginPreview(
                                        coordinate: CLLocationCoordinate2D(
                                            latitude: entry.latitude,
                                            longitude: entry.longitude
                                        ),
                                        name: entry.name,
                                        subtitle: entry.subtitle
                                    )
                                    dismiss()
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .font(.title3)
                                            .foregroundStyle(colors.neonBlue)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.name)
                                                .font(.body.weight(.medium))
                                                .foregroundStyle(colors.textPrimary)
                                            if !entry.subtitle.isEmpty {
                                                Text(entry.subtitle)
                                                    .font(.caption)
                                                    .foregroundStyle(colors.textSecondary)
                                            }
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .listRowBackground(colors.bgCard)
                            }
                            .onDelete { indexSet in
                                for index in indexSet {
                                    DestinationSearchHistory.remove(id: history[index].id)
                                }
                                history = DestinationSearchHistory.all()
                            }
                        }
                    }
                } else if results.isEmpty {
                    Section {
                        Text("No matches yet.")
                            .font(.subheadline)
                            .foregroundStyle(colors.textSecondary)
                            .listRowBackground(Color.clear)
                    }
                } else {
                    ForEach(results, id: \.self) { result in
                        Button {
                            app.navigationService.selectCompletion(result)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(colors.neonBlue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.title)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(colors.textPrimary)
                                    if !result.subtitle.isEmpty {
                                        Text(result.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(colors.textSecondary)
                                    }
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .listRowBackground(colors.bgCard)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(colors.bgDeep.ignoresSafeArea())
            .navigationTitle("Set destination")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Address or place")
            .onChange(of: query) { _, newValue in
                app.navigationService.searchQuery = newValue
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .tint(colors.neonGreen)
                }
            }
            .onAppear {
                query = app.navigationService.searchQuery
                history = DestinationSearchHistory.all()
            }
        }
    }
}
