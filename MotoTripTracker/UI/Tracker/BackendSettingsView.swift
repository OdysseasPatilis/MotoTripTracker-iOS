import SwiftUI

/// Configure the MotoTripTracker backend URL for post-ride cloud upload.
struct BackendSettingsView: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = BackendSettings.baseURL

    var body: some View {
        let colors = theme.palette

        NavigationStack {
            Form {
                Section {
                    TextField("http://192.168.1.10:8080", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.body.monospaced())
                } header: {
                    Text("Server URL")
                } footer: {
                    Text("Leave empty to disable upload. Use your Mac's LAN IP while testing locally. Rides upload automatically after you stop.")
                }

                Section {
                    HStack {
                        Text("Upload")
                        Spacer()
                        Text(BackendSettings.isEnabled ? "Enabled" : "Disabled")
                            .foregroundStyle(BackendSettings.isEnabled ? colors.neonGreen : colors.textSecondary)
                            .fontWeight(.semibold)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(colors.bgDeep.ignoresSafeArea())
            .navigationTitle("Cloud Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") {
                        urlText = ""
                        BackendSettings.setBaseURL("")
                    }
                    .disabled(urlText.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        BackendSettings.setBaseURL(urlText)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .tint(colors.neonGreen)
                }
            }
        }
        .onAppear {
            urlText = BackendSettings.baseURL
        }
    }
}
