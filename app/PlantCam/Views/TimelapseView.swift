import Photos
import SwiftUI

struct TimelapseView: View {
    @EnvironmentObject var settings: AppSettings
    @StateObject private var model = TimelapseModel()
    @State private var showingNote = false
    @State private var noteText = ""

    private let markerColor = Color(red: 0.76, green: 0.42, blue: 0.11)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Picker("View", selection: $model.plantView) {
                        ForEach(PlantView.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    if !PhotoService.shared.hasAccess {
                        placeholder(
                            "Photos access is off",
                            "Allow it in Settings so Plant Cam can find your albums."
                        )
                    } else if model.hasLoaded && model.assets.isEmpty {
                        placeholder(
                            "Nothing in \(model.plantView.label) yet",
                            "Photos filed under \(model.plantView.label) go in the album \u{201C}\(model.plantView.albumName)\u{201D} and play here."
                        )
                    } else {
                        player
                    }
                }
                .padding()
            }
            .navigationTitle("Timelapse")
            .onAppear {
                model.sprout = settings.sproutDate
                model.stabilize = settings.stabilize
                model.smartPacing = settings.smartPacing
                model.reload()
            }
            .onDisappear { model.pause() }
            .onChange(of: settings.sproutDate) { _, newValue in model.sprout = newValue }
            .onChange(of: settings.stabilize) { _, newValue in model.stabilize = newValue }
            .onChange(of: settings.smartPacing) { _, newValue in model.smartPacing = newValue }
            .alert("Add a note", isPresented: $showingNote) {
                TextField("Short note", text: $noteText)
                Button("Save") {
                    model.addNote(noteText)
                    noteText = ""
                }
                Button("Cancel", role: .cancel) { noteText = "" }
            } message: {
                Text("Attached to day \(model.dayNumber(at: model.currentFrame) ?? 0).")
            }
        }
    }

    // MARK: Pieces

    private func placeholder(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var player: some View {
        VStack(spacing: 14) {
            photoView
            header
            if let note = model.noteText(at: model.currentFrame) {
                Text(note)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(markerColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            controls
            Text(summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Picker("Speed", selection: $model.speed) {
                ForEach(PlaybackSpeed.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            actions
            exportArea
        }
    }

    private var summary: String {
        var text = "\(model.plan.count) frame\(model.plan.count == 1 ? "" : "s")"
        if model.plan.count != model.assets.count {
            text += " from \(model.assets.count) photos"
        }
        if model.stabilized {
            text += ", lined up on the background"
        } else if model.plantView == .nodes {
            text += ", close-ups fade without lining up"
        }
        return text
    }

    private var photoView: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let image = model.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                }
            }
            if model.preparing {
                VStack(spacing: 6) {
                    ProgressView(value: model.prepareProgress)
                    Text("Lining up photos\u{2026}")
                        .font(.footnote)
                }
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(10)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(model.aspect, contentMode: .fit)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(dayLabel)
                .font(.system(size: 36, weight: .semibold, design: .rounded))
            Spacer()
            Text(dateLabel)
                .foregroundStyle(.secondary)
        }
    }

    private var dayLabel: String {
        model.dayNumber(at: model.currentFrame).map { "Day \($0)" } ?? "Day \u{2013}"
    }

    private var dateLabel: String {
        model.date(at: model.currentFrame)?.formatted(date: .abbreviated, time: .omitted) ?? ""
    }

    private var position: Binding<Double> {
        Binding(
            get: { model.position },
            set: { newValue in model.seek(newValue) }
        )
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button {
                model.togglePlay()
            } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Theme.green.opacity(model.plan.count < 2 || model.preparing ? 0.4 : 1), in: Circle())
            }
            .disabled(model.plan.count < 2 || model.preparing)
            .accessibilityLabel(model.playing ? "Pause" : "Play")

            if model.plan.count > 1 {
                VStack(spacing: 2) {
                    markerRow
                    Slider(value: position, in: 0...Double(max(1, model.plan.count - 1)))
                        .accessibilityLabel("Choose a day")
                }
            } else {
                Spacer()
            }
        }
    }

    private var markerRow: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                ForEach(model.markers) { marker in
                    Circle()
                        .fill(markerColor)
                        .frame(width: 8, height: 8)
                        .offset(x: 12 + (proxy.size.width - 24) * marker.fraction - 4)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(height: 8)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            NavigationLink {
                CompareView(plantView: model.plantView)
            } label: {
                Label("Compare", systemImage: "rectangle.split.2x1")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(model.assets.count < 2)

            Button {
                showingNote = true
            } label: {
                Label("Note", systemImage: "note.text.badge.plus")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var exportArea: some View {
        switch model.exportState {
        case .idle:
            Button {
                model.saveVideo()
            } label: {
                Text("Save video")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.preparing)
        case .working(let progress):
            VStack(alignment: .leading, spacing: 6) {
                Text("Making the video\u{2026}").font(.subheadline)
                ProgressView(value: progress)
            }
        case .saved:
            VStack(spacing: 8) {
                Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.green)
                Button("Make another") { model.resetExport() }
            }
        case .failed(let message):
            VStack(spacing: 8) {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                Button("Try again") { model.saveVideo() }
            }
        }
    }
}
