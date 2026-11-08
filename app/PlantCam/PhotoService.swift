import Foundation
import Photos
import UIKit

enum PhotoError: LocalizedError {
    case notFound(String)
    case outsideRange
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let id): return "No photo with id \(id)."
        case .outsideRange: return "That photo is from before the sprout date, so it isn't shared."
        case .failed(let message): return message
        }
    }
}

struct PhotoJPEG {
    let data: Data
    let taken: String
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
}
