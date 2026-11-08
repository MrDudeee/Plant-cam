import AVFoundation
import Photos
import UIKit

enum VideoExportError: LocalizedError {
    case noFrames
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noFrames: return "There are no photos to put in a video."
        case .failed(let message): return message
        }
    }
}

/// Turns a list of photos into an MP4, one photo per frame, with a "Day N" label on each.
enum VideoExporter {
    static let width = 1080
    static let height = 1440

    private static let labelDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    static func export(
        assets: [PHAsset],
        sprout: Date,
        framesPerSecond: Int32,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        guard !assets.isEmpty else { throw VideoExportError.noFrames }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plant-timelapse-\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else { throw VideoExportError.failed("Couldn't set up the video.") }
        writer.add(input)
        guard writer.startWriting() else {
            throw VideoExportError.failed(writer.error?.localizedDescription ?? "Couldn't start the video.")
        }
        writer.startSession(atSourceTime: .zero)

        for (i, asset) in assets.enumerated() {
            let picture = await PhotoService.shared.image(for: asset, longEdge: 1440)
            var label = ""
            if let taken = asset.creationDate {
                let day = DayMath.dayNumber(of: taken, sprout: sprout)
                label = "Day \(day)  \u{00B7}  \(labelDate.string(from: taken))"
            }
            let frame = composeFrame(picture, label: label)

            while !input.isReadyForMoreMediaData {
                if writer.status == .failed {
                    throw VideoExportError.failed(writer.error?.localizedDescription ?? "The video stopped.")
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard let pool = adaptor.pixelBufferPool, let buffer = makeBuffer(from: frame, pool: pool) else {
                throw VideoExportError.failed("Couldn't prepare a frame.")
            }
            let time = CMTime(value: CMTimeValue(i), timescale: framesPerSecond)
            if !adaptor.append(buffer, withPresentationTime: time) {
                throw VideoExportError.failed(writer.error?.localizedDescription ?? "Couldn't add a frame.")
            }
            progress(Double(i + 1) / Double(assets.count))
        }

        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw VideoExportError.failed(writer.error?.localizedDescription ?? "The video didn't finish.")
        }
        return url
    }

    static func saveToPhotos(_ url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Drawing

    private static func composeFrame(_ picture: UIImage?, label: String) -> UIImage {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            UIColor(red: 0.12, green: 0.16, blue: 0.12, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))

            if let picture = picture, picture.size.width > 0, picture.size.height > 0 {
                let fit = min(size.width / picture.size.width, size.height / picture.size.height)
                let drawWidth = picture.size.width * fit
                let drawHeight = picture.size.height * fit
                picture.draw(in: CGRect(
                    x: (size.width - drawWidth) / 2,
                    y: (size.height - drawHeight) / 2,
                    width: drawWidth,
                    height: drawHeight
                ))
            }

            if !label.isEmpty {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 52, weight: .semibold),
                    .foregroundColor: UIColor.white,
                ]
                let text = NSAttributedString(string: label, attributes: attributes)
                let textSize = text.size()
                let pill = CGRect(
                    x: 40,
                    y: size.height - textSize.height - 84,
                    width: textSize.width + 48,
                    height: textSize.height + 24
                )
                UIColor(white: 0, alpha: 0.55).setFill()
                UIBezierPath(roundedRect: pill, cornerRadius: 24).fill()
                text.draw(at: CGPoint(x: pill.minX + 24, y: pill.minY + 12))
            }
        }
    }

    private static func makeBuffer(from image: UIImage, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var created: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created) == kCVReturnSuccess,
              let buffer = created,
              let cgImage = image.cgImage else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
