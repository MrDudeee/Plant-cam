import SwiftUI

@main
struct PlantCamApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var relay: RelayClient
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let appSettings = AppSettings()
        _settings = StateObject(wrappedValue: appSettings)
        _relay = StateObject(wrappedValue: RelayClient(settings: appSettings))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(relay)
                .tint(Theme.green)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                relay.pauseForBackground()
            case .active:
                relay.resumeIfNeeded()
            default:
                break
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        if settings.hasSeenWelcome {
            MainTabs()
        } else {
            WelcomeView()
        }
    }
}

struct MainTabs: View {
    var body: some View {
        TabView {
            ConnectView()
                .tabItem { Label("Connect", systemImage: "antenna.radiowaves.left.and.right") }
            ComingSoonView(
                title: "Timelapse",
                detail: "Per-view timelapses, Compare days, and timeline notes arrive in the next build."
            )
            .tabItem { Label("Timelapse", systemImage: "play.rectangle") }
            ComingSoonView(
                title: "Capture",
                detail: "The camera with your last photo as a guide arrives in a later build."
            )
            .tabItem { Label("Capture", systemImage: "camera") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
        }
    }
}

enum Theme {
    static let green = Color(red: 47.0 / 255.0, green: 107.0 / 255.0, blue: 46.0 / 255.0)
}
