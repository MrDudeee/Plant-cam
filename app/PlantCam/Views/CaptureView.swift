import AVFoundation
import SwiftUI
import UIKit

struct CaptureView: View {
    @StateObject private var camera = CameraModel()
    @State private var plantView: PlantView = .side
    @AppStorage("ghostOn") private var ghostOn = true
    @AppStorage("ghostOpacity") private var ghostOpacity = 0.35

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Picker("View", selection: $plantView) {
                        ForEach(PlantView.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    cameraArea
                    options
                    shutter

                    Text(camera.message)
                        .font(.subheadline)
                        .foregroundStyle(camera.message.hasPrefix("Saved") ? Theme.green : .secondary)
                        .frame(minHeight: 20)
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .navigationTitle("Capture")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                Task { await camera.start(view: plantView) }
            }
            .onDisappear { camera.stop() }
            .onChange(of: plantView) { _, newValue in
                camera.select(view: newValue)
            }
        }
    }

    // MARK: Pieces

    private var cameraArea: some View {
        ZStack {
            Color.black
            if camera.permission == .authorized {
                CameraPreview(session: camera.session, running: camera.running) { point in
                    camera.focus(atDevicePoint: point)
                }
                if ghostOn, let ghost = camera.ghost {
                    Image(uiImage: ghost)
                        .resizable()
                        .scaledToFit()
                        .opacity(ghostOpacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            } else {
                permissionMessage
            }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var permissionMessage: some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.fill")
                .font(.system(size: 30))
                .accessibilityHidden(true)
            if camera.permission == .notDetermined {
                Text("Allow the camera when iOS asks.")
            } else {
                Text("Camera access is off.")
                Button("Open iPhone Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .padding()
    }

    private var options: some View {
        VStack(spacing: 10) {
            Toggle("Show last photo as a guide", isOn: $ghostOn)
            if ghostOn {
                Slider(value: $ghostOpacity, in: 0.1...0.7)
                    .accessibilityLabel("Guide strength")
            }
            if camera.hasUltraWide {
                Picker("Lens", selection: $camera.lens) {
                    ForEach(Lens.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var shutter: some View {
        Button {
            camera.capture(view: plantView)
        } label: {
            ZStack {
                Circle()
                    .stroke(Theme.green, lineWidth: 4)
                    .frame(width: 76, height: 76)
                Circle()
                    .fill(Color.white)
                    .frame(width: 60, height: 60)
                if camera.busy {
                    ProgressView()
                }
            }
        }
        .disabled(camera.busy || camera.permission != .authorized)
        .accessibilityLabel("Take photo")
    }
}
