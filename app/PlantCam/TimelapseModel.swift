import Foundation
import Photos
import SwiftUI
import UIKit

enum PlaybackSpeed: String, CaseIterable, Identifiable {
    case slow, normal, fast

    var id: String { rawValue }

    var label: String {
        switch self {
        case .slow: return "Slow"
        case .normal: return "Normal"
        case .fast: return "Fast"
        }
    }

    /// Seconds each photo stays on screen.
    var seconds: Double {
        switch self {
        case .slow: return 0.6
        case .normal: return 0.3
        case .fast: return 0.12
        }
    }

    /// Photos per second in a saved video.
    var videoFPS: Int32 {
        switch self {
        case .slow: return 2
        case .normal: return 4
        case .fast: return 8
        }
    }
}

struct NoteMarker: Identifiable {
    let id: String
    let fraction: Double
    let text: String
}

enum ExportState {
    case idle
    case working(Double)
    case saved
    case failed(String)
}

/// Plays the photos filed under one view (side, overhead, or nodes) in date order.
@MainActor
final class TimelapseModel: ObservableObject {
    @Published var plantView: PlantView = .side {
        didSet { if plantView != oldValue { reload() } }
    }
    @Published private(set) var assets: [PHAsset] = []
    @Published var index = 0 {
        didSet { if index != oldValue { showCurrent() } }
    }
    @Published private(set) var image: UIImage?
    @Published private(set) var playing = false
    @Published var speed: PlaybackSpeed = .normal
    @Published private(set) var notes: [String: String] = [:]
    @Published private(set) var markers: [NoteMarker] = []
    @Published private(set) var hasLoaded = false
    @Published private(set) var exportState: ExportState = .idle

    var sprout = Date()

    private let caching = PHCachingImageManager()
    private var playTask: Task<Void, Never>?
    private var token = 0
    private let displaySize = CGSize(width: 900, height: 900)

    init() {
        caching.allowsCachingHighQualityImages = false
    }

    // MARK: Loading

    func reload() {
        pause()
        caching.stopCachingImagesForAllAssets()
        assets = PhotoService.shared.assets(in: plantView)
        notes = NotesStore.shared.all()
        rebuildMarkers()
        hasLoaded = true
        if assets.count <= 400 {
            caching.startCachingImages(for: assets, targetSize: displaySize, contentMode: .aspectFit, options: makeOptions())
        }
        let last = max(0, assets.count - 1)
        if index == last {
            showCurrent()
        } else {
            index = last
        }
    }

    private func makeOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return options
    }

    private func showCurrent() {
        guard assets.indices.contains(index) else {
            image = nil
            return
        }
        token += 1
        let mine = token
        caching.requestImage(
            for: assets[index],
            targetSize: displaySize,
            contentMode: .aspectFit,
            options: makeOptions()
        ) { [weak self] picture, _ in
            guard let picture = picture else { return }
            Task { @MainActor in
                guard let self = self, mine == self.token else { return }
                self.image = picture
            }
        }
    }

    // MARK: Playback

    func togglePlay() {
        if playing { pause() } else { play() }
    }

    func play() {
        guard assets.count > 1, !playing else { return }
        if index >= assets.count - 1 { index = 0 }
        playing = true
        playTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                let delay = UInt64(self.speed.seconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delay)
                if Task.isCancelled || !self.playing { return }
                self.index = (self.index + 1) % max(1, self.assets.count)
            }
        }
    }

    func pause() {
        playing = false
        playTask?.cancel()
        playTask = nil
    }

    // MARK: Days and notes

    func date(at i: Int) -> Date? {
        guard assets.indices.contains(i) else { return nil }
        return assets[i].creationDate
    }

    func dayNumber(at i: Int) -> Int? {
        guard let taken = date(at: i) else { return nil }
        return DayMath.dayNumber(of: taken, sprout: sprout)
    }

    /// Notes that fall between the previous photo's day and this photo's day.
    func noteText(at i: Int) -> String? {
        guard let taken = date(at: i) else { return nil }
        let day = DayFormat.string(taken)
        let previous: String? = i > 0 ? date(at: i - 1).map { DayFormat.string($0) } : nil
        let hits = notes.filter { entry in
            entry.key <= day && (previous.map { entry.key > $0 } ?? true)
        }
        if hits.isEmpty { return nil }
        return hits.sorted { $0.key < $1.key }.map { $0.value }.joined(separator: " · ")
    }

    func addNote(_ text: String) {
        guard let taken = date(at: index) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        NotesStore.shared.add(date: DayFormat.string(taken), text: String(trimmed.prefix(80)))
        notes = NotesStore.shared.all()
        rebuildMarkers()
    }

    private func rebuildMarkers() {
        guard !assets.isEmpty else {
            markers = []
            return
        }
        let days = assets.map { asset in asset.creationDate.map { DayFormat.string($0) } ?? "" }
        var built: [NoteMarker] = []
        for (key, text) in notes.sorted(by: { $0.key < $1.key }) {
            guard let position = days.firstIndex(where: { $0 >= key }) else { continue }
            let fraction = assets.count > 1 ? Double(position) / Double(assets.count - 1) : 0
            built.append(NoteMarker(id: key, fraction: fraction, text: text))
        }
        markers = built
    }

    // MARK: Saving a video

    func saveVideo() {
        guard !assets.isEmpty else { return }
        if case .working = exportState { return }
        pause()
        exportState = .working(0)
        let chosen = assets
        let start = sprout
        let fps = speed.videoFPS
        Task {
            do {
                let url = try await VideoExporter.export(assets: chosen, sprout: start, framesPerSecond: fps) { value in
                    Task { @MainActor in self.exportState = .working(value) }
                }
                try await VideoExporter.saveToPhotos(url)
                exportState = .saved
            } catch {
                exportState = .failed(error.localizedDescription)
            }
        }
    }

    func resetExport() {
        exportState = .idle
    }
}
