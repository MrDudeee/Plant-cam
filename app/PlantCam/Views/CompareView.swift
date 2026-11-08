import Photos
import SwiftUI

/// Two days of the same view, one above the other. Pinching either one zooms both to the same spot.
struct CompareView: View {
    let plantView: PlantView
    @EnvironmentObject var settings: AppSettings
    @StateObject private var zoom = ZoomState()
    @State private var assets: [PHAsset] = []
    @State private var first = 0
    @State private var second = 0
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if loaded && assets.count < 2 {
                    Text("Compare needs at least two photos in \(plantView.label).")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 48)
                } else if assets.count >= 2 {
                    panel(index: $first)
                    panel(index: $second)
                    Text(gapText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Pinch or double-tap either photo to zoom both to the same spot.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if plantView == .nodes {
                        Text("Put today next to a few days ago and look for anything new in the crook of a node.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Compare days")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load() }
    }

    private func load() {
        assets = PhotoService.shared.assets(in: plantView)
        loaded = true
        guard assets.count >= 2 else { return }
        second = assets.count - 1
        first = max(0, assets.count - 6)
    }

    /// Panels follow the photos' own shape, so portrait photos aren't squeezed into a wide box.
    private var panelAspect: CGFloat {
        guard assets.indices.contains(second) else { return 0.75 }
        let latest = assets[second]
        let ratio = CGFloat(latest.pixelWidth) / CGFloat(max(1, latest.pixelHeight))
        return min(2.0, max(0.5, ratio))
    }

    private func panel(index: Binding<Int>) -> some View {
        let safe = min(max(index.wrappedValue, 0), max(0, assets.count - 1))
        let asset = assets.indices.contains(safe) ? assets[safe] : nil
        let dayText = asset?.creationDate.map {
            "Day \(DayMath.dayNumber(of: $0, sprout: settings.sproutDate))"
        } ?? "Day \u{2013}"
        let dateText = asset?.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? ""
        return VStack(spacing: 8) {
            ZoomableFrame(zoom: zoom) {
                FrameImage(asset: asset, longEdge: 2200)
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(panelAspect, contentMode: .fit)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(alignment: .topTrailing) { ZoomResetButton(zoom: zoom) }
            .accessibilityHint("Pinch to zoom, double-tap to zoom in")
            HStack {
                Text(dayText).font(.headline)
                Text(dateText).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            }
            Slider(
                value: Binding(
                    get: { Double(safe) },
                    set: { index.wrappedValue = Int($0.rounded()) }
                ),
                in: 0...Double(max(1, assets.count - 1)),
                step: 1
            )
            .accessibilityLabel("Choose a day")
        }
    }

    private var gapText: String {
        guard assets.indices.contains(first), assets.indices.contains(second),
              let a = assets[first].creationDate, let b = assets[second].creationDate else { return "" }
        let days = DayMath.daysBetween(a, b)
        return days == 1 ? "1 day apart" : "\(days) days apart"
    }
}
