import Photos
import SwiftUI
import UIKit

/// Loads and shows one photo from the library.
struct FrameImage: View {
    let asset: PHAsset?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if asset != nil {
                ProgressView()
            }
        }
        .task(id: asset?.localIdentifier) {
            guard let asset = asset else {
                image = nil
                return
            }
            image = await PhotoService.shared.image(for: asset, longEdge: 900)
        }
    }
}
