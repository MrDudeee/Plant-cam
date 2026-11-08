import SwiftUI
import UIKit

struct ConnectView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var relay: RelayClient

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(dotColor)
                            .frame(width: 14, height: 14)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(.headline)
                            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)

                    if relay.isOn {
                        Button("Stop connection", role: .destructive) { relay.stop() }
                    } else {
                        Button("Start connection") { relay.start() }
                            .fontWeight(.semibold)
                    }
                }

                Section {
                    LabeledContent("Sharing photos from", value: settings.sproutDate.formatted(date: .abbreviated, time: .omitted))
                    Toggle("Stay connected when I switch apps", isOn: $settings.keepInBackground)
                    Toggle("Keep screen on while connected", isOn: $settings.keepScreenOn)
                } footer: {
                    Text("Staying connected plays silence so iOS keeps Plant Cam running while you chat with Claude. It uses a little extra battery, so tap Stop connection when you\u{2019}re done.")
                }

                Section("Recent activity") {
                    if relay.activity.isEmpty {
                        Text("What Claude does shows up here while you\u{2019}re connected.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(relay.activity) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.text)
                                Text(item.time.formatted(date: .omitted, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Connect")
        }
        .onChange(of: relay.status) { _, _ in updateIdleTimer() }
        .onChange(of: settings.keepScreenOn) { _, _ in updateIdleTimer() }
        .onChange(of: settings.keepInBackground) { _, _ in relay.backgroundSettingChanged() }
    }

    private var title: String {
        switch relay.status {
        case .off: return "Not connected"
        case .connecting: return "Connecting\u{2026}"
        case .connected: return "Connected to Claude"
        case .failed: return "Couldn\u{2019}t connect"
        }
    }

    private var subtitle: String {
        switch relay.status {
        case .off: return "Tap Start so Claude can reach your photos."
        case .connecting: return "Reaching the relay."
        case .connected: return "Claude can ask for photos now."
        case .failed(let message): return message
        }
    }

    private var dotColor: Color {
        switch relay.status {
        case .connected: return Color(red: 0.18, green: 0.54, blue: 0.23)
        case .connecting: return .orange
        case .failed: return .red
        case .off: return Color(.systemGray3)
        }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn && relay.status == .connected
    }
}
