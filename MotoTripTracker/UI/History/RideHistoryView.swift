import SwiftUI

enum RideHistoryTab: String, CaseIterable, Identifiable {
    case all = "All"
    case favorites = "Favorites"
    var id: String { rawValue }
}

enum DateFilterPreset: String, CaseIterable, Identifiable {
    case any = "Any time"
    case today = "Today"
    case yesterday = "Yesterday"
    case thisWeek = "This week"
    case thisMonth = "This month"
    case custom = "Custom"
    var id: String { rawValue }
}

private enum CustomDateField {
    case from
    case to
}

struct RideHistoryView: View {
    @Environment(AppContainer.self) private var app
    @Environment(ThemeStore.self) private var theme

    @State private var allRides: [Trip] = []
    @State private var selectedTab: RideHistoryTab = .all
    @State private var searchQuery = ""
    @State private var datePreset: DateFilterPreset = .any
    @State private var customFrom: Date = Calendar.current.startOfDay(for: Date())
    @State private var customTo: Date = Date()
    @State private var activeCustomField: CustomDateField?

    private var visibleRides: [Trip] {
        filterRides(allRides)
    }

    var body: some View {
        let colors = theme.palette

        List {
            Section {
                Picker("Show", selection: $selectedTab) {
                    ForEach(RideHistoryTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }

            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(DateFilterPreset.allCases) { preset in
                            Button {
                                selectDatePreset(preset)
                            } label: {
                                Text(preset.rawValue)
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .foregroundStyle(datePreset == preset ? Color.white : colors.textPrimary)
                                    .background(
                                        datePreset == preset ? colors.neonGreen : colors.bgPanel,
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)

                if datePreset == .custom {
                    HStack(spacing: 12) {
                        Button {
                            activeCustomField = .from
                        } label: {
                            dateChipLabel("From", date: customFrom, colors: colors)
                        }
                        .buttonStyle(.plain)

                        Button {
                            activeCustomField = .to
                        } label: {
                            dateChipLabel("To", date: customTo, colors: colors)
                        }
                        .buttonStyle(.plain)
                    }
                    .listRowBackground(Color.clear)
                }
            }

            if visibleRides.isEmpty {
                Section {
                    ContentUnavailableView(
                        emptyTitle,
                        systemImage: "bicycle",
                        description: Text(emptyDescription)
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(visibleRides, id: \.id) { ride in
                        NavigationLink(value: AppRoute.summary(ride.id)) {
                            RideHistoryRow(ride: ride, colors: colors)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                app.repository.toggleFavorite(id: ride.id)
                                reload()
                            } label: {
                                Label(
                                    ride.isFavorite ? "Unfavorite" : "Favorite",
                                    systemImage: ride.isFavorite ? "star.slash" : "star.fill"
                                )
                            }
                            .tint(colors.routeAmber)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(colors.bgDeep.ignoresSafeArea())
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchQuery, prompt: "Search rides")
        .onAppear { reload() }
        .sheet(item: $activeCustomField) { field in
            CustomDatePickerSheet(
                title: field == .from ? "From date" : "To date",
                selection: field == .from ? $customFrom : $customTo,
                colors: colors
            )
            .presentationDetents([.medium])
            .onDisappear { normalizeCustomRange() }
        }
    }

    private var emptyTitle: String {
        if !searchQuery.isEmpty || datePreset != .any || selectedTab == .favorites {
            return "No Matching Rides"
        }
        return "No Rides Yet"
    }

    private var emptyDescription: String {
        if !searchQuery.isEmpty || datePreset != .any || selectedTab == .favorites {
            return "Try adjusting your search or filters."
        }
        return "Start a ride from the tracker to see it here."
    }

    private func dateChipLabel(_ title: String, date: Date, colors: AppPalette) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(colors.textSecondary)
            Text(Self.shortDate.string(from: date))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(colors.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(colors.bgCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func selectDatePreset(_ preset: DateFilterPreset) {
        datePreset = preset
        if preset == .custom {
            let calendar = Calendar.current
            customFrom = calendar.startOfDay(for: Date())
            customTo = endOfDay(Date())
        }
    }

    private func normalizeCustomRange() {
        if customFrom > customTo {
            swap(&customFrom, &customTo)
        }
        customFrom = Calendar.current.startOfDay(for: customFrom)
        customTo = endOfDay(customTo)
    }

    private func endOfDay(_ date: Date) -> Date {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? date
    }

    private func reload() {
        allRides = app.repository.allTrips()
    }

    private func filterRides(_ rides: [Trip]) -> [Trip] {
        var scoped = rides
        if selectedTab == .favorites {
            scoped = scoped.filter(\.isFavorite)
        }
        scoped = scoped.filter { matchesDate($0) }

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return scoped }
        return scoped.filter {
            $0.displayTitle.lowercased().contains(query)
                || RideFormatters.timestampToDate($0.startTime).lowercased().contains(query)
        }
    }

    private func matchesDate(_ ride: Trip) -> Bool {
        let date = Date(timeIntervalSince1970: ride.startTime)
        let calendar = Calendar.current
        let now = Date()

        switch datePreset {
        case .any:
            return true
        case .today:
            return calendar.isDateInToday(date)
        case .yesterday:
            return calendar.isDateInYesterday(date)
        case .thisWeek:
            return calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear)
        case .thisMonth:
            return calendar.isDate(date, equalTo: now, toGranularity: .month)
        case .custom:
            let start = calendar.startOfDay(for: min(customFrom, customTo))
            let end = endOfDay(max(customFrom, customTo))
            return date >= start && date <= end
        }
    }

    private static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

extension CustomDateField: Identifiable {
    var id: String {
        switch self {
        case .from: "from"
        case .to: "to"
        }
    }
}

private struct CustomDatePickerSheet: View {
    let title: String
    @Binding var selection: Date
    let colors: AppPalette
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DatePicker(
                title,
                selection: $selection,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .padding()
            .tint(colors.neonGreen)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct RideHistoryRow: View {
    let ride: Trip
    let colors: AppPalette

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bicycle")
                .font(.body.weight(.semibold))
                .foregroundStyle(colors.neonGreen)
                .frame(width: 32, height: 32)
                .background(colors.neonGreen.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(ride.displayTitle)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(colors.textPrimary)
                        .lineLimit(1)
                    if ride.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(colors.routeAmber)
                    }
                }
                Text(RideFormatters.timestampToDate(ride.startTime))
                    .font(.caption)
                    .foregroundStyle(colors.textSecondary)
                Text(
                    String(
                        format: "%@ · %.1f km · %d km/h avg",
                        RideFormatters.secondsToTime(ride.totalTime),
                        ride.distanceKm,
                        Int(ride.avgSpeed)
                    )
                )
                .font(.caption)
                .foregroundStyle(colors.textMuted)
            }
        }
        .padding(.vertical, 4)
    }
}
