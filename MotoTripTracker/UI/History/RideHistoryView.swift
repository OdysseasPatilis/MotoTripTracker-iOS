import SwiftUI

enum RideHistoryTab: String, CaseIterable, Identifiable {
    case all = "All"
    case favorites = "Favorites"
    var id: String { rawValue }
}

enum DateFilterPreset: String, CaseIterable, Identifiable {
    case any = "Any"
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
    @Environment(\.dismiss) private var dismiss

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

        ZStack {
            colors.bgDeep.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                ScreenTopBar(title: "Ride History", onBack: { dismiss() })
                tabPicker(colors: colors)
                searchField(colors: colors)
                dateFilterRow(colors: colors)
                if datePreset == .custom {
                    customDateRow(colors: colors)
                }

                if visibleRides.isEmpty {
                    Spacer()
                    Text(emptyMessage)
                        .font(.system(size: 14))
                        .foregroundStyle(colors.emptyText)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(visibleRides, id: \.id) { ride in
                                NavigationLink(value: AppRoute.summary(ride.id)) {
                                    RideHistoryCard(
                                        ride: ride,
                                        colors: colors,
                                        onToggleFavorite: {
                                            app.repository.toggleFavorite(id: ride.id)
                                            reload()
                                        }
                                    )
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

    private var emptyMessage: String {
        if !searchQuery.isEmpty || datePreset != .any || selectedTab == .favorites {
            return "No rides match your filters"
        }
        return "No rides recorded yet"
    }

    private func tabPicker(colors: AppPalette) -> some View {
        HStack(spacing: 8) {
            ForEach(RideHistoryTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.rawValue.uppercased())
                        .font(.system(size: 12, weight: .bold))
                        .tracking(1)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .foregroundStyle(selectedTab == tab ? .white : colors.textMuted)
                        .background(selectedTab == tab ? colors.layerActive : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private func searchField(colors: AppPalette) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(colors.textMuted)
            TextField("Search rides", text: $searchQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(colors.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(colors.bgCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    private func dateFilterRow(colors: AppPalette) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DateFilterPreset.allCases) { preset in
                    Button {
                        selectDatePreset(preset)
                    } label: {
                        Text(preset.rawValue)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .foregroundStyle(datePreset == preset ? colors.neonGreen : colors.textMuted)
                            .background(
                                datePreset == preset ? colors.neonGreen.opacity(0.15) : colors.bgCard,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.vertical, 10)
    }

    private func customDateRow(colors: AppPalette) -> some View {
        HStack(spacing: 10) {
            customDateChip(
                label: "From",
                date: customFrom,
                colors: colors
            ) {
                activeCustomField = .from
            }
            customDateChip(
                label: "To",
                date: customTo,
                colors: colors
            ) {
                activeCustomField = .to
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func customDateChip(
        label: String,
        date: Date,
        colors: AppPalette,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .medium))
                    .tracking(1)
                    .foregroundStyle(colors.textMuted)
                Text(Self.shortDate.string(from: date))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colors.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(colors.bgCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(colors.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
            ZStack {
                colors.bgDeep.ignoresSafeArea()
                DatePicker(
                    title,
                    selection: $selection,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .padding()
                .tint(colors.neonGreen)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(colors.neonGreen)
                }
            }
        }
    }
}

struct RideHistoryCard: View {
    let ride: Trip
    let colors: AppPalette
    var onToggleFavorite: (() -> Void)?

    var body: some View {
        ZStack(alignment: .leading) {
            colors.bgCard

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
                    Text(ride.displayTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(colors.neonGreen)
                        .lineLimit(1)
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

                Button {
                    onToggleFavorite?()
                } label: {
                    Image(systemName: ride.isFavorite ? "star.fill" : "star")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(ride.isFavorite ? colors.routeAmber : colors.emptyText)
                }
                .buttonStyle(.plain)

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
