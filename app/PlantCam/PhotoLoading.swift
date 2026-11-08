import Foundation
import Photos
import UIKit

enum DayMath {
    /// Day 1 is the sprout date itself.
    static func dayNumber(of date: Date, sprout: Date) -> Int {
        let calendar = Calendar.current
        let from = calendar.startOfDay(for: sprout)
        let to = calendar.startOfDay(for: date)
        return (calendar.dateComponents([.day], from: from, to: to).day ?? 0) + 1
    }

    static func daysBetween(_ first: Date, _ second: Date) -> Int {
        let calendar = Calendar.current
        let from = calendar.startOfDay(for: first)
        let to = calendar.startOfDay(for: second)
        return abs(calendar.dateComponents([.day], from: from, to: to).day ?? 0)
    }
}

extension PhotoService {
    /// Photos filed under a view, oldest first.
    func assets(in view: PlantView) -> [PHAsset] {
        guard let collection = try? album(for: view, create: false) else { return [] }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let fetched = PHAsset.fetchAssets(in: collection, options: options)
        var result: [PHAsset] = []
        result.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in result.append(asset) }
        return result
    }

    /// One photo, scaled so its longest side is at most `longEdge` pixels.
    func image(for asset: PHAsset, longEdge: CGFloat) async -> UIImage? {
        let longest = CGFloat(max(asset.pixelWidth, asset.pixelHeight, 1))
        let scale = min(1, longEdge / longest)
        let target = CGSize(
            width: max(1, (CGFloat(asset.pixelWidth) * scale).rounded()),
            height: max(1, (CGFloat(asset.pixelHeight) * scale).rounded())
        )
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        return await withCheckedContinuation { continuation in
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
                continuation.resume(returning: image)
            }
        }
    }
}
