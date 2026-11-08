import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var relay: RelayClient
    @State private var address = ""
    @State private var password = ""
    @State private var saved = false
    @State private var accessLabel = PhotoService.shared.accessDescription

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Sprout date", selection: $settings.sproutDate, displayedComponents: .date)
                    ForEach(PlantView.allCases) { view in
                        LabeledContent("\(view.label) photos", value: "Album: \(view.albumName)")
                    }
                } header: {
                    Text("Your plant")
                } footer: {
                    Text("Day counts start at the sprout date, and only photos from then on are shared with Claude.")
                }

                Section {
                    Picker("Photo size", selection: $settings.photoSize) {
                        ForEach(PhotoSize.allCases) { size in
                            Text(size.label).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Photo size sent to Claude")
                } footer: {
                    Text("Large is clearest for checking nodes. Small is quickest for sorting.")
                }

                Section {
                    TextField("https://plant-cam-relay.you.workers.dev", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Relay password", text: $password)
                    Button(saved ? "Saved" : "Save relay details") { saveRelay() }
                        .disabled(address.isEmpty || password.isEmpty || saved)
                } header: {
                    Text("Relay")
                } footer: {
                    Text("From the setup steps. The password is kept in your iPhone’s keychain.")
                }

                Section {
                    LabeledContent("Photos access", value: accessLabel)
                    Button("Open iPhone Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }

                Section {
                    LabeledContent("Version", value: versionText)
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                address = settings.relayAddress
                password = settings.relayPassword
                saved = false
                accessLabel = PhotoService.shared.accessDescription
            }
            .onChange(of: address) { _, _ in saved = false }
            .onChange(of: password) { _, _ in saved = false }
        }
    }

    private func saveRelay() {
        settings.relayAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.relayPassword = password
        saved = true
        if relay.isOn {
            relay.stop()
            relay.start()
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
