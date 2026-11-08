import Foundation
import Photos
import QuartzCore
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

    /// Seconds each photo takes to fade into the next.
    var seconds: Double {
        switch self {
        case .slow: return 0.6
        case .normal: return 0.3
        case .fast: return 0.12
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

/// Plays the photos filed under one view as a smooth timelapse: lined up on what holds still,
/// colors matched, and faded from one photo to the next.
@MainActor
final class TimelapseModel: ObservableObject {
    @Published var plantView: PlantView = .side {
        didSet { if plantView != oldValue { reload() } }
    }
    @Published private(set) var assets: [PHAsset] = []
    /// The photos that are shown, in order, each with how long its fade lasts.
    @Published private(set) var plan: [PacedFrame] = []
    /// 0 is the first frame; 2.5 is halfway between the third and fourth.
    @Published private(set) var position: Double = 0
    @Published private(set) var image: UIImage?
    @Published private(set) var aspect: CGFloat = 0.75
    @Published private(set) var playing = false
    @Published var speed: PlaybackSpeed = .normal
    @Published private(set) var notes: [String: String] = [:]
    @Published private(set) var markers: [NoteMarker] = []
    @Published private(set) var hasLoaded = false
    @Published private(set) var preparing = false
    @Published private(set) var prepareProgress = 0.0
    @Published private(set) var stabilized = false
    @Published private(set) var exportState: ExportState = .idle

    var sprout = Date()
    var stabilize = true {
        didSet { if stabilize != oldValue { rebuild() } }
    }
    var smartPacing = true {
        didSet { if smartPacing != oldValue { rebuild() } }
    }

    private var fixes: [FrameFix] = []
    private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var useFixes = false
    private var images: [Int: CIImage] = [:]
    private var sharpImages: [Int: CIImage] = [:]
    private var fixCache: [String: FrameFix] = [:]

    private var playTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var sharpTask: Task<Void, Never>?
    private var prepareGeneration = 0
    private var renderBusy = false
    private var renderQueued = false
    private var holdRemaining = 0.0
    private var lastPrefetch = -1

    // MARK: Loading

    func reload() {
        pause()
        prefetchTask?.cancel()
        sharpTask?.cancel()
        images = [:]
        sharpImages = [:]
        assets = PhotoService.shared.assets(in: plantView)
        notes = NotesStore.shared.all()
        hasLoaded = true
        rebuild()
    }

    private func rebuild() {
        pause()
        prepareTask?.cancel()
        prefetchTask?.cancel()
        sharpTask?.cancel()
        prepareGeneration += 1
        let generation = prepareGeneration
        preparing = false
        prepareProgress = 0

        plan = Pacing.plan(dates: assets.map { $0.creationDate }, smart: smartPacing)
        fixes = Array(repeating: FrameFix(), count: plan.count)
        crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        useFixes = false
        stabilized = false
        rebuildMarkers()

        if let lastIndex = plan.last?.index, assets.indices.contains(lastIndex) {
            let latest = assets[lastIndex]
            aspect = CGFloat(latest.pixelWidth) / CGFloat(max(1, latest.pixelHeight))
        }
        position = Double(max(0, plan.count - 1))
        renderNow()

        if plan.count > 1, stabilize, plantView != .nodes {
            prepareTask = Task { [weak self] in
                await self?.prepare(generation: generation)
            }
        }
    }

    // MARK: Lining the photos up

    private func smallImage(_ assetIndex: Int) async -> CGImage? {
        guard assets.indices.contains(assetIndex) else { return nil }
        let picture = await PhotoService.shared.image(for: assets[assetIndex], longEdge: 320)
        return picture?.uprightCGImage()
    }

    private func prepare(generation: Int) async {
        func isCurrent() -> Bool {
            generation == prepareGeneration && !Task.isCancelled
        }
        func cacheKey(_ reference: String, _ id: String) -> String {
            reference + "|" + id
        }
        guard isCurrent() else { return }
        let frames = plan
        let ids = frames.map { assets[$0.index].localIdentifier }
        guard let lastID = ids.last else { return }
        preparing = true
        prepareProgress = 0

        if ids.allSatisfy({ fixCache[cacheKey(lastID, $0)] != nil }) {
            apply(ids.map { fixCache[cacheKey(lastID, $0)] ?? FrameFix() })
            return
        }

        // The latest photo with enough background is the one everything lines up with.
        var session: StabilizerSession?
        var referencePosition = frames.count - 1
        while referencePosition >= 0 {
            guard isCurrent() else { return }
            if let small = await smallImage(frames[referencePosition].index),
               let made = StabilizerSession(reference: small) {
                session = made
                break
            }
            referencePosition -= 1
        }
        guard let session = session else {
            if isCurrent() { preparing = false }
            return
        }

        let referenceID = ids[referencePosition]
        var result = [FrameFix](repeating: FrameFix(), count: frames.count)
        for k in frames.indices {
            guard isCurrent() else { return }
            let key = cacheKey(referenceID, ids[k])
            if let stored = fixCache[key] {
                result[k] = stored
            } else if k == referencePosition {
                result[k] = session.referenceFix()
                fixCache[key] = result[k]
            } else if let small = await smallImage(frames[k].index) {
                let computed = await Task.detached(priority: .userInitiated) {
                    session.fix(for: small)
                }.value
                result[k] = computed
                fixCache[key] = computed
            }
            prepareProgress = Double(k + 1) / Double(frames.count)
        }
        if isCurrent() { apply(result) }
    }

    private func apply(_ result: [FrameFix]) {
        fixes = result
        crop = Stabilizer.crop(for: result)
        useFixes = true
        stabilized = true
        preparing = false
        renderNow()
    }

    private func fix(at k: Int) -> FrameFix {
        fixes.indices.contains(k) ? fixes[k] : FrameFix()
    }

    // MARK: Drawing

    private func ciImage(for assetIndex: Int) async -> CIImage? {
        if let cached = images[assetIndex] { return cached }
        guard assets.indices.contains(assetIndex),
              let picture = await PhotoService.shared.image(for: assets[assetIndex], longEdge: 1200),
              let image = FrameRenderer.normalizedImage(picture) else { return nil }
        images[assetIndex] = image
        trimCache(keeping: assetIndex)
        return image
    }

    private func trimCache(keeping index: Int) {
        guard images.count > 14, !plan.isEmpty else { return }
        let here = currentFrame
        var keep: Set<Int> = [index]
        for k in plan.indices where abs(k - here) <= 5 {
            keep.insert(plan[k].index)
        }
        images = images.filter { keep.contains($0.key) }
    }

    private func prefetch() {
        prefetchTask?.cancel()
        guard plan.count > 1 else { return }
        let start = min(plan.count - 1, max(0, Int(position)))
        let wanted = (0...4).map { (start + $0) % plan.count }
        prefetchTask = Task { [weak self] in
            for k in wanted {
                guard let self = self, !Task.isCancelled else { return }
                guard self.plan.indices.contains(k) else { continue }
                _ = await self.ciImage(for: self.plan[k].index)
            }
        }
    }

    /// Draws the picture for the current position. If a picture is already being drawn,
    /// this waits and draws the newest position next, so playback never queues up.
    func renderNow() {
        guard !plan.isEmpty else {
            image = nil
            return
        }
        if renderBusy {
            renderQueued = true
            return
        }
        renderBusy = true
        let p = position
        let k = min(plan.count - 1, max(0, Int(p)))
        let nextK = min(plan.count - 1, k + 1)
        let mix = nextK == k ? 0 : min(1, max(0, p - Double(k)))
        let assetA = plan[k].index
        let assetB = plan[nextK].index
        let fixA = fix(at: k)
        let fixB = fix(at: nextK)
        Task { [weak self] in
            guard let self = self else { return }
            let picture = await self.makePicture(assetA: assetA, assetB: assetB, fixA: fixA, fixB: fixB, mix: mix)
            if let picture = picture { self.image = picture }
            self.renderBusy = false
            if self.renderQueued {
                self.renderQueued = false
                self.renderNow()
            } else if !self.playing {
                self.scheduleSharp()
            }
        }
    }

    private func makePicture(assetA: Int, assetB: Int, fixA: FrameFix, fixB: FrameFix, mix: Double) async -> UIImage? {
        guard let imageA = await ciImage(for: assetA) else { return nil }
        let a = RenderSource(image: imageA, fix: fixA)
        var b: RenderSource?
        if mix > 0.001, let imageB = await ciImage(for: assetB) {
            b = RenderSource(image: imageB, fix: fixB)
        }
        let size = FrameRenderer.canvasSize(aspect: aspect, longEdge: 1000)
        let cropRect = crop
        let apply = useFixes
        return await Task.detached(priority: .userInitiated) {
            FrameRenderer.shared.render(a, b, mix: mix, crop: cropRect, size: size, useFixes: apply)
        }.value
    }

    // MARK: A sharper picture when playback stops

    /// Playback draws small pictures to keep moving smoothly. When it stops, one large picture
    /// replaces the current one so zooming in stays clear.
    private func scheduleSharp() {
        sharpTask?.cancel()
        guard !plan.isEmpty else { return }
        let startPosition = position
        sharpTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self = self, !Task.isCancelled, !self.playing, !self.preparing,
                  !self.renderBusy, self.position == startPosition else { return }
            await self.renderSharp()
        }
    }

    private func renderSharp() async {
        guard !plan.isEmpty else { return }
        let p = position
        let k = min(plan.count - 1, max(0, Int(p)))
        let nextK = min(plan.count - 1, k + 1)
        let mix = nextK == k ? 0 : min(1, max(0, p - Double(k)))
        let assetA = plan[k].index
        let assetB = plan[nextK].index
        let fixA = fix(at: k)
        let fixB = fix(at: nextK)
        guard let imageA = await sharpImage(for: assetA) else { return }
        let a = RenderSource(image: imageA, fix: fixA)
        var b: RenderSource?
        if mix > 0.001, let imageB = await sharpImage(for: assetB) {
            b = RenderSource(image: imageB, fix: fixB)
        }
        let size = FrameRenderer.canvasSize(aspect: aspect, longEdge: 2400)
        let cropRect = crop
        let apply = useFixes
        let picture = await Task.detached(priority: .userInitiated) {
            FrameRenderer.shared.render(a, b, mix: mix, crop: cropRect, size: size, useFixes: apply)
        }.value
        guard !Task.isCancelled, !playing, position == p, let picture = picture else { return }
        image = picture
    }

    private func sharpImage(for assetIndex: Int) async -> CIImage? {
        if let cached = sharpImages[assetIndex] { return cached }
        guard assets.indices.contains(assetIndex),
              let picture = await PhotoService.shared.image(for: assets[assetIndex], longEdge: 2400),
              let image = FrameRenderer.normalizedImage(picture) else { return nil }
        if sharpImages.count >= 4 { sharpImages = [:] }
        sharpImages[assetIndex] = image
        return image
    }

    // MARK: Playback

    func togglePlay() {
        if playing {
            pause()
            scheduleSharp()
        } else {
            play()
        }
    }

    func play() {
        guard plan.count > 1, !playing, !preparing else { return }
        sharpTask?.cancel()
        if position >= Double(plan.count - 1) - 0.001 { position = 0 }
        playing = true
        holdRemaining = 0
        lastPrefetch = -1
        playTask = Task { [weak self] in
            var last = CACurrentMediaTime()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000)
                guard let self = self, self.playing else { return }
                let now = CACurrentMediaTime()
                let dt = min(0.25, now - last)
                last = now
                self.advance(by: dt)
            }
        }
    }

    func pause() {
        playing = false
        playTask?.cancel()
        playTask = nil
    }

    func seek(_ value: Double) {
        pause()
        holdRemaining = 0
        position = min(Double(max(0, plan.count - 1)), max(0, value))
        renderNow()
    }

    /// Moves forward in time. Each photo's fade lasts its own length, so long gaps linger a little.
    private func advance(by dt: Double) {
        guard plan.count > 1 else { return }
        let last = Double(plan.count - 1)
        if holdRemaining > 0 {
            holdRemaining -= dt
            if holdRemaining <= 0 {
                holdRemaining = 0
                position = 0
                renderNow()
            }
            return
        }
        let k = min(plan.count - 1, max(0, Int(position)))
        let dwell = max(0.05, speed.seconds * plan[k].weight)
        let next = position + dt / dwell
        if next >= last {
            position = last
            holdRemaining = 0.8
        } else {
            position = next
        }
        renderNow()
        if Int(position) != lastPrefetch {
            lastPrefetch = Int(position)
            prefetch()
        }
    }

    // MARK: Days and notes

    var currentFrame: Int {
        min(max(0, Int(position.rounded())), max(0, plan.count - 1))
    }

    func date(at k: Int) -> Date? {
        guard plan.indices.contains(k), assets.indices.contains(plan[k].index) else { return nil }
        return assets[plan[k].index].creationDate
    }

    func dayNumber(at k: Int) -> Int? {
        guard let taken = date(at: k) else { return nil }
        return DayMath.dayNumber(of: taken, sprout: sprout)
    }

    /// Notes that fall between the previous frame's day and this frame's day.
    func noteText(at k: Int) -> String? {
        guard let taken = date(at: k) else { return nil }
        let day = DayFormat.string(taken)
        let previous: String? = k > 0 ? date(at: k - 1).map { DayFormat.string($0) } : nil
        let hits = notes.filter { entry in
            entry.key <= day && (previous.map { entry.key > $0 } ?? true)
        }
        if hits.isEmpty { return nil }
        return hits.sorted { $0.key < $1.key }.map { $0.value }.joined(separator: " \u{00B7} ")
    }

    func addNote(_ text: String) {
        guard let taken = date(at: currentFrame) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        NotesStore.shared.add(date: DayFormat.string(taken), text: String(trimmed.prefix(80)))
        notes = NotesStore.shared.all()
        rebuildMarkers()
    }

    private func rebuildMarkers() {
        guard !plan.isEmpty else {
            markers = []
            return
        }
        let days: [String] = plan.map { frame in
            guard assets.indices.contains(frame.index), let taken = assets[frame.index].creationDate else { return "" }
            return DayFormat.string(taken)
        }
        var built: [NoteMarker] = []
        for (key, text) in notes.sorted(by: { $0.key < $1.key }) {
            guard let found = days.firstIndex(where: { $0 >= key }) else { continue }
            let fraction = plan.count > 1 ? Double(found) / Double(plan.count - 1) : 0
            built.append(NoteMarker(id: key, fraction: fraction, text: text))
        }
        markers = built
    }

    // MARK: Saving a video

    func saveVideo() {
        guard !plan.isEmpty, !preparing else { return }
        if case .working = exportState { return }
        pause()
        exportState = .working(0)
        var chosen: [ExportFrame] = []
        for (k, frame) in plan.enumerated() where assets.indices.contains(frame.index) {
            chosen.append(ExportFrame(asset: assets[frame.index], fix: fix(at: k), weight: frame.weight))
        }
        let cropRect = crop
        let apply = useFixes
        let seconds = speed.seconds
        let start = sprout
        Task {
            do {
                let url = try await VideoExporter.export(
                    frames: chosen,
                    crop: cropRect,
                    useFixes: apply,
                    secondsPerPhoto: seconds,
                    sprout: start
                ) { value in
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
