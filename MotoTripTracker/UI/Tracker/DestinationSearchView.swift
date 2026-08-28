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

    var body: some View {
        let colors = theme.palette
        let results = app.navigationService.searchResults

        NavigationStack {
            List {
                if results.isEmpty {
                    Section {
                        Text(query.isEmpty
                             ? "Search for an address or place to set as your destination."
                             : "No matches yet.")
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
            }
        }
    }
}
