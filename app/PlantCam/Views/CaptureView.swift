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
                    zoomBar
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
                CameraPreview(
                    session: camera.session,
                    running: camera.running,
                    onTap: { point in camera.focus(atDevicePoint: point) },
                    onPinchBegan: { camera.pinchBegan() },
                    onPinchChanged: { scale in camera.pinchChanged(scale) }
                )
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

    // MARK: Zoom

    private var presets: [CGFloat] {
        let wanted: [CGFloat] = [0.5, 1, 2, 3, 5]
        return wanted.filter { $0 >= camera.minZoom - 0.01 && $0 <= camera.maxZoom + 0.01 }
    }

    private func zoomLabel(_ value: CGFloat) -> String {
        if value == value.rounded() {
            return "\(Int(value))\u{00D7}"
        }
        return String(format: "%.1f\u{00D7}", Double(value))
    }

    private func isActive(_ value: CGFloat) -> Bool {
        abs(camera.zoom - value) < 0.08
    }

    private var zoomBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ForEach(presets, id: \.self) { value in
                    Button {
                        camera.setZoom(value)
                    } label: {
                        Text(zoomLabel(value))
                            .font(.subheadline.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 36)
                            .padding(.horizontal, 4)
                            .background(
                                isActive(value) ? Theme.green : Color(.secondarySystemBackground),
                                in: Capsule()
                            )
                            .foregroundStyle(isActive(value) ? Color.white : Color.primary)
                    }
                    .accessibilityLabel("Zoom \(zoomLabel(value))")
                }
            }
            Text("Zoom \(String(format: "%.1f", Double(camera.zoom)))\u{00D7} \u{00B7} pinch the picture to zoom, tap to focus")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var options: some View {
        VStack(spacing: 10) {
            Toggle("Show last photo as a guide", isOn: $ghostOn)
            if ghostOn {
                Slider(value: $ghostOpacity, in: 0.1...0.7)
                    .accessibilityLabel("Guide strength")
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
