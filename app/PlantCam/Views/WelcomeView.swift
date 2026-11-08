import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var asking = false
    @State private var denied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(Theme.green, in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Plant Cam")
                        .font(.largeTitle.bold())
                    Text("Lets Claude look at your plant photos while this app is open, and plays them back as a timelapse.")
                        .foregroundStyle(.secondary)
                }

                point(
                    icon: "iphone",
                    title: "Only while it’s open",
                    text: "Claude can reach your photos only while Plant Cam is on screen. Leave the app and the connection ends."
                )
                point(
                    icon: "checkmark.shield",
                    title: "No copies kept",
                    text: "Each photo goes straight to Claude when asked. The relay passes it along and saves nothing."
                )
                point(
                    icon: "calendar",
                    title: "From your sprout date on",
                    text: "Only photos taken on or after the sprout date are shared. You can change the date in Settings."
                )

                if denied {
                    Text("Photos access is off. You can turn it on in the iPhone Settings app under Plant Cam, then Photos.")
                        .font(.callout)
                        .foregroundStyle(.red)
                    Button("Continue without access") { settings.hasSeenWelcome = true }
                }

                VStack(spacing: 12) {
                    Button {
                        Task { await ask() }
                    } label: {
                        Text(asking ? "Asking…" : "Allow photo access")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(asking)

                    Text("iOS asks next. Choose “Allow Full Access” so Claude can find every plant photo.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(24)
            .padding(.top, 32)
        }
    }

    private func point(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.green)
                .frame(width: 40, height: 40)
                .background(Theme.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    @MainActor
    private func ask() async {
        asking = true
        let status = await PhotoService.shared.requestAccess()
        asking = false
        if status == .authorized || status == .limited {
            settings.hasSeenWelcome = true
        } else {
            denied = true
        }
    }
}
