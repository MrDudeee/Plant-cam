import AVFoundation
import Foundation
import Photos
import UIKit

enum PhotoError: LocalizedError {
    case notFound(String)
    case outsideRange
    case videoOutsideRange
    case notAVideo(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let id): return "No photo or video with id \(id)."
        case .outsideRange: return "That photo is from before the sprout date, so it isn't shared."
        case .videoOutsideRange: return "That video is from before the sprout date, so it isn't shared. The user can change the sprout date in Plant Cam's Settings."
        case .notAVideo(let id): return "\(id) is a photo, not a video. Use view_photos for photos."
        case .failed(let message): return message
        }
    }
}

struct PhotoJPEG {
    let data: Data
    let taken: String
}

struct VideoFrame {
    let data: Data
    let label: String
}

final class PhotoService {
    static let shared = PhotoService()

    private let listFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    var hasAccess: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    var accessDescription: String {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: return "Full access"
        case .limited: return "Selected photos only"
        case .denied, .restricted: return "Off"
        case .notDetermined: return "Not asked yet"
        @unknown default: return "Unknown"
        }
    }

    func requestAccess() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    // MARK: Albums

    func album(for view: PlantView, create: Bool) throws -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", view.albumName)
        let found = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
        if let existing = found.firstObject { return existing }
        guard create else { return nil }

        var placeholderID: String?
        try PHPhotoLibrary.shared().performChangesAndWait {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: view.albumName)
            placeholderID = request.placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let id = placeholderID else { return nil }
        return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
    }

    /// Which views each photo is filed under, keyed by photo id.
    func membership() -> [String: [PlantView]] {
        var result: [String: [PlantView]] = [:]
        for view in PlantView.allCases {
            guard let collection = try? album(for: view, create: false) else { continue }
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            assets.enumerateObjects { asset, _, _ in
                result[asset.localIdentifier, default: []].append(view)
            }
        }
        return result
    }

    func file(ids: [String], view: PlantView, remove: Bool) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        guard let collection = try album(for: view, create: !remove) else { return 0 }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        if assets.count == 0 { return 0 }
        try PHPhotoLibrary.shared().performChangesAndWait {
            guard let request = PHAssetCollectionChangeRequest(for: collection) else { return }
            if remove {
                request.removeAssets(assets)
            } else {
                request.addAssets(assets)
            }
        }
        return assets.count
    }

    // MARK: Listing

    func listPhotos(since: Date, until: Date?, view: String?, limit: Int, offset: Int) -> String {
        let options = PHFetchOptions()
        var predicates = [NSPredicate(format: "creationDate >= %@", since as NSDate)]
        if let until = until {
            predicates.append(NSPredicate(format: "creationDate < %@", until as NSDate))
        }
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        let members = membership()

        var rows: [String] = []
        var matched = 0
        assets.enumerateObjects { asset, _, _ in
            let views = members[asset.localIdentifier] ?? []
            if let wanted = view {
                if wanted == "unsorted" {
                    if !views.isEmpty { return }
                } else if !views.contains(where: { $0.rawValue == wanted }) {
                    return
                }
            }
            matched += 1
            if matched <= offset || rows.count >= limit { return }
            let date = asset.creationDate.map { self.listFormatter.string(from: $0) } ?? "unknown"
            let filed = views.isEmpty ? "-" : views.map { $0.rawValue }.joined(separator: ",")
            rows.append("\(asset.localIdentifier) | \(date) | \(asset.pixelWidth)x\(asset.pixelHeight) | \(filed)")
        }

        var header = "\(matched) photo(s) match. Showing \(rows.count)"
        if offset > 0 { header += " after skipping \(offset)" }
        header += "."
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited {
            header += " Note: the user gave access to selected photos only."
        }
        return ([header] + rows).joined(separator: "\n")
    }

    func listVideos(since: Date, until: Date?, limit: Int, offset: Int) -> String {
        let options = PHFetchOptions()
        var predicates = [NSPredicate(format: "creationDate >= %@", since as NSDate)]
        if let until = until {
            predicates.append(NSPredicate(format: "creationDate < %@", until as NSDate))
        }
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets = PHAsset.fetchAssets(with: .video, options: options)

        var rows: [String] = []
        var matched = 0
        assets.enumerateObjects { asset, _, _ in
            matched += 1
            if matched <= offset || rows.count >= limit { return }
            let date = asset.creationDate.map { self.listFormatter.string(from: $0) } ?? "unknown"
            rows.append("\(asset.localIdentifier) | \(date) | \(self.clock(asset.duration)) | \(asset.pixelWidth)x\(asset.pixelHeight)")
        }

        var header = "\(matched) video(s) match. Showing \(rows.count)"
        if offset > 0 { header += " after skipping \(offset)" }
        header += "."
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited {
            header += " Note: the user gave access to selected photos and videos only."
        }
        return ([header] + rows).joined(separator: "\n")
    }

    // MARK: Images

    func jpeg(for id: String, longEdge: CGFloat, notBefore: Date) async throws -> PhotoJPEG {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw PhotoError.notFound(id)
        }
        if let created = asset.creationDate, created < notBefore {
            throw PhotoError.outsideRange
        }
        let longest = CGFloat(max(asset.pixelWidth, asset.pixelHeight, 1))
        let scale = min(1, longEdge / longest)
        let target = CGSize(
            width: max(1, (CGFloat(asset.pixelWidth) * scale).rounded()),
            height: max(1, (CGFloat(asset.pixelHeight) * scale).rounded())
        )

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        let image: UIImage = try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: target,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                if resumed { return }
                if let degraded = info?[PHImageResultIsDegradedKey] as? Bool, degraded { return }
                resumed = true
                if let image = image {
                    continuation.resume(returning: image)
                } else {
                    let message = (info?[PHImageErrorKey] as? Error)?.localizedDescription ?? "Couldn't load this photo."
                    continuation.resume(throwing: PhotoError.failed(message))
                }
            }
        }

        guard let data = image.jpegData(compressionQuality: 0.7) else {
            throw PhotoError.failed("Couldn't convert this photo.")
        }
        let taken = asset.creationDate.map { listFormatter.string(from: $0) } ?? "unknown date"
        return PhotoJPEG(data: data, taken: taken)
    }

    // MARK: Videos

    /// Pulls still frames out of one video and hands each to `onFrame` as soon as it is ready.
    /// Frames are spread evenly across the chosen stretch, or the whole video by default.
    /// Returns a one-line summary for Claude.
    func videoFrames(
        id: String,
        count: Int,
        start: Double?,
        end: Double?,
        longEdge: CGFloat,
        notBefore: Date,
        onFrame: (VideoFrame) async -> Void
    ) async throws -> String {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw PhotoError.notFound(id)
        }
        guard asset.mediaType == .video else {
            throw PhotoError.notAVideo(id)
        }
        if let created = asset.creationDate, created < notBefore {
            throw PhotoError.videoOutsideRange
        }
        let total = asset.duration
        guard total > 0 else {
            throw PhotoError.failed("This video has no length.")
        }

        let from = min(max(0, start ?? 0), total)
        let to = min(max(from, end ?? total), total)
        let span = to - from
        var times: [Double] = []
        if span < 0.1 || count == 1 {
            times = [from + span / 2]
        } else {
            times = (0..<count).map { from + span * (Double($0) + 0.5) / Double(count) }
        }

        let video = try await avAsset(for: asset)
        let generator = AVAssetImageGenerator(asset: video)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: longEdge, height: longEdge)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var shown = 0
        for t in times {
            let time = CMTime(seconds: t, preferredTimescale: 600)
            do {
                let result = try await generator.image(at: time)
                let picture = UIImage(cgImage: result.image)
                guard let data = picture.jpegData(compressionQuality: 0.7) else { continue }
                let label = "\(clock(result.actualTime.seconds)) of \(clock(total))"
                await onFrame(VideoFrame(data: data, label: label))
                shown += 1
            } catch {
                continue
            }
        }
        if shown == 0 {
            throw PhotoError.failed("Couldn't read any frames from this video.")
        }

        let taken = asset.creationDate.map { listFormatter.string(from: $0) } ?? "unknown date"
        var summary = "Video taken \(taken), \(clock(total)) long, \(asset.pixelWidth)x\(asset.pixelHeight). "
        summary += "Showed \(shown) frame\(shown == 1 ? "" : "s") from \(clock(from)) to \(clock(to)). No sound is included."
        if shown < times.count {
            summary += " \(times.count - shown) frame(s) couldn't be read."
        }
        return summary
    }

    private func avAsset(for asset: PHAsset) async throws -> AVAsset {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { video, _, info in
                if let video = video {
                    continuation.resume(returning: video)
                } else {
                    let message = (info?[PHImageErrorKey] as? Error)?.localizedDescription ?? "Couldn't open this video."
                    continuation.resume(throwing: PhotoError.failed(message))
                }
            }
        }
    }

    /// Seconds as m:ss.s, for example 0:05.2.
    private func clock(_ seconds: Double) -> String {
        let whole = max(0, seconds)
        let minutes = Int(whole) / 60
        let rest = whole - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, rest)
    }
}
