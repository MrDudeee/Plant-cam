import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var relay: RelayClient
    @State private var address = ""
    @State private var password = ""
    @State private var saved = false
    @State private var accessLabel = PhotoService.shared.accessDescription
    @State private var reminderDenied = false

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
                    Toggle("Remind me daily", isOn: $settings.reminderOn)
                    DatePicker("Time", selection: reminderTime, displayedComponents: .hourAndMinute)
                        .disabled(!settings.reminderOn)
                } header: {
                    Text("Photo reminder")
                } footer: {
                    if reminderDenied {
                        Text("Notifications are off for Plant Cam. Turn them on in the iPhone Settings app, then try again.")
                    } else {
                        Text("A daily nudge to take your side, overhead and close-up shots.")
                    }
                }

                Section {
                    Toggle("Line photos up", isOn: $settings.stabilize)
                    Picker("Pacing", selection: $settings.smartPacing) {
                        Text("Smart").tag(true)
                        Text("Every photo").tag(false)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Timelapse")
                } footer: {
                    Text("Lining up keeps the view steady by matching the pot, ring and wall, and ignores the plant. Node close-ups only fade, since they have no fixed background. Smart pacing shows one photo per day, the one closest to your usual time, and lingers a little on longer gaps.")
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
                    Text("From the setup steps. The password is kept in your iPhone\u{2019}s keychain.")
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
            .onChange(of: settings.reminderOn) { _, _ in applyReminder() }
            .onChange(of: settings.reminderMinutes) { _, _ in applyReminder() }
        }
    }

    /// The time as a date, since the picker wants one. Stored as minutes after midnight.
    private var reminderTime: Binding<Date> {
        Binding(
            get: {
                var parts = DateComponents()
                parts.hour = settings.reminderMinutes / 60
                parts.minute = settings.reminderMinutes % 60
                return Calendar.current.date(from: parts) ?? Date()
            },
            set: { newValue in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                settings.reminderMinutes = (parts.hour ?? 9) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private func applyReminder() {
        let on = settings.reminderOn
        let minutes = settings.reminderMinutes
        Task {
            let ok = await PhotoReminder.apply(enabled: on, minutes: minutes)
            reminderDenied = on && !ok
            if on && !ok { settings.reminderOn = false }
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
