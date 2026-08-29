import SwiftUI
import UIKit

/// Sheet for tank capacity, consumption, remaining fuel, fill-up, and petrol preferences.
struct FuelSettingsView: View {
    @Environment(AppContainer.self) private var app
    @Environment(ThemeStore.self) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var showPetrolPicker = false

    private let octaneOptions = [95, 98, 100]

    var body: some View {
        @Bindable var fuel = app.fuelService
        @Bindable var petrol = app.petrolPreferences
        let colors = theme.palette

        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Estimated range")
                        Spacer()
                        Text(fuel.rangeSummary)
                            .foregroundStyle(fuel.isLowFuel ? colors.neonRed : colors.neonGreen)
                            .fontWeight(.semibold)
                    }
                    ProgressView(value: fuel.fuelFraction)
                        .tint(fuel.isLowFuel ? colors.neonRed : colors.neonGreen)
                    HStack {
                        Text("Fuel left")
                        Spacer()
                        Text(String(format: "%.1f / %.0f L", fuel.fuelRemainingLiters, fuel.tankCapacityLiters))
                            .foregroundStyle(colors.textSecondary)
                    }
                    if let filled = fuel.lastFillDate {
                        HStack {
                            Text("Last fill-up")
                            Spacer()
                            Text(filled.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(colors.textSecondary)
                        }
                    }
                } header: {
                    Text("Range")
                }

                Section {
                    Stepper(value: $fuel.tankCapacityLiters, in: 5...40, step: 0.5) {
                        Text("Tank \(String(format: "%.1f", fuel.tankCapacityLiters)) L")
                    }
                    Stepper(value: $fuel.consumptionLPer100Km, in: 2.5...12, step: 0.1) {
                        Text("Use \(String(format: "%.1f", fuel.consumptionLPer100Km)) L/100 km")
                    }
                    Stepper(value: $fuel.fuelRemainingLiters, in: 0...fuel.tankCapacityLiters, step: 0.5) {
                        Text("Remaining \(String(format: "%.1f", fuel.fuelRemainingLiters)) L")
                    }
                } header: {
                    Text("Bike fuel")
                } footer: {
                    Text("Range is estimated from remaining fuel and your average consumption. It updates automatically as you ride.")
                }

                Section {
                    ForEach(octaneOptions, id: \.self) { octane in
                        Toggle(isOn: Binding(
                            get: { petrol.preferredOctanes.contains(octane) },
                            set: { _ in petrol.toggleOctane(octane) }
                        )) {
                            Text("\(octane) octane")
                        }
                        .tint(colors.neonGreen)
                    }
                } header: {
                    Text("Preferred petrol")
                } footer: {
                    Text("Stations advertising these grades are ranked higher in recommendations.")
                }

                Section {
                    ForEach(PetrolPreferences.catalog, id: \.self) { brand in
                        Toggle(isOn: Binding(
                            get: { petrol.preferredBrands.contains(brand) },
                            set: { _ in petrol.toggleBrand(brand) }
                        )) {
                            Text(brand)
                        }
                        .tint(colors.neonGreen)
                    }
                } header: {
                    Text("Preferred brands")
                } footer: {
                    Text("Enabled brands are preferred in order from top to bottom. Drag to reorder your priority list below.")
                }

                if !petrol.preferredBrands.isEmpty {
                    Section {
                        ForEach(petrol.preferredBrands, id: \.self) { brand in
                            Text(brand)
                        }
                        .onMove { source, destination in
                            petrol.moveBrand(from: source, to: destination)
                        }
                    } header: {
                        Text("Brand priority")
                    } footer: {
                        Text("First in the list is tried first (e.g. Shell, then BP).")
                    }
                }

                Section {
                    Button {
                        fuel.fillUp()
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    } label: {
                        Label("Fill up to full", systemImage: "fuelpump.fill")
                    }
                    .tint(colors.neonGreen)

                    Button {
                        showPetrolPicker = true
                    } label: {
                        Label("Find petrol stations", systemImage: "mappin.and.ellipse")
                    }
                    .tint(colors.neonBlue)
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(colors.bgDeep.ignoresSafeArea())
            .navigationTitle("Fuel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .tint(colors.neonGreen)
                }
            }
            .sheet(isPresented: $showPetrolPicker) {
                PetrolStationsView()
            }
        }
    }
}
