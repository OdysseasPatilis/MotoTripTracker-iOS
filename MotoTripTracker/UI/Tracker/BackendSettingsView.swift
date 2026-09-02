import SwiftUI

/// Configure the MotoTripTracker backend URL for post-ride cloud upload.
struct BackendSettingsView: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = BackendSettings.baseURL
    @State private var testMessage: String?
    @State private var isTesting = false

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
                    Text("Leave empty to disable upload. Use your Mac's LAN IP, e.g. http://192.168.1.10:8080 — include http://. Rides upload automatically after you stop.")
                }

                Section {
                    HStack {
                        Text("Upload")
                        Spacer()
                        Text(BackendSettings.isEnabled ? "Enabled" : "Disabled")
                            .foregroundStyle(BackendSettings.isEnabled ? colors.neonGreen : colors.textSecondary)
                            .fontWeight(.semibold)
                    }
                    HStack {
                        Text("ATS cleartext")
                        Spacer()
                        Text(BackendSettings.allowsArbitraryLoadsInBundle ? "Allowed" : "Blocked")
                            .foregroundStyle(
                                BackendSettings.allowsArbitraryLoadsInBundle ? colors.neonGreen : colors.neonRed
                            )
                            .fontWeight(.semibold)
                    }
                } footer: {
                    if !BackendSettings.allowsArbitraryLoadsInBundle {
                        Text("This install is missing ATS HTTP permission. Delete the app from the phone, then rebuild & run from Xcode.")
                    }
                }

                Section {
                    Button {
                        Task { await runConnectionTest() }
                    } label: {
                        if isTesting {
                            ProgressView()
                        } else {
                            Text("Test connection")
                        }
                    }
                    .disabled(isTesting || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let testMessage {
                        Text(testMessage)
                            .font(.footnote)
                            .foregroundStyle(colors.textSecondary)
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
                        testMessage = nil
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

    @MainActor
    private func runConnectionTest() async {
        BackendSettings.setBaseURL(urlText)
        urlText = BackendSettings.baseURL
        isTesting = true
        testMessage = nil
        defer { isTesting = false }
        do {
            testMessage = try await TripCloudUploader.testConnection()
        } catch {
            testMessage = error.localizedDescription
        }
    }
}
