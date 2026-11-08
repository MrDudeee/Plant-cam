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

struct ExportFrame {
    let asset: PHAsset
    let fix: FrameFix
    let weight: Double
}

/// Turns the timelapse into an MP4: 30 frames a second, lined up and faded from photo to photo,
/// with a "Day N" label.
enum VideoExporter {
    static let framesPerSecond: Int32 = 30

    private static let labelDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    static func export(
        frames: [ExportFrame],
        crop: CGRect,
        useFixes: Bool,
        secondsPerPhoto: Double,
        sprout: Date,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        guard let reference = frames.last?.asset else { throw VideoExportError.noFrames }
        let aspect = CGFloat(reference.pixelWidth) / CGFloat(max(1, reference.pixelHeight))
        let size = FrameRenderer.canvasSize(aspect: aspect, longEdge: 1440)
        let width = Int(size.width)
        let height = Int(size.height)

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

        let fps = Double(framesPerSecond)
        let counts: [Int] = frames.indices.map { k in
            if k == frames.count - 1 { return Int(fps * 0.8) }
            return max(1, Int((secondsPerPhoto * frames[k].weight * fps).rounded()))
        }
        let total = max(1, counts.reduce(0, +))
        var written = 0

        var current = try await load(frames[0])
        for k in frames.indices {
            var upcoming: RenderSource?
            if k + 1 < frames.count {
                upcoming = try await load(frames[k + 1])
            }
            for j in 0..<counts[k] {
                let mix = upcoming == nil ? 0 : Double(j) / Double(counts[k])
                let shown = mix < 0.5 ? k : min(k + 1, frames.count - 1)
                let label = labelText(for: frames[shown].asset, sprout: sprout)

                let buffer: CVPixelBuffer = try autoreleasepool {
                    guard let picture = FrameRenderer.shared.render(
                        current,
                        upcoming,
                        mix: mix,
                        crop: crop,
                        size: size,
                        useFixes: useFixes
                    ) else { throw VideoExportError.failed("Couldn't draw a frame.") }
                    let finished = labeled(picture, label: label, size: size)
                    guard let pool = adaptor.pixelBufferPool,
                          let made = makeBuffer(from: finished, pool: pool, width: width, height: height) else {
                        throw VideoExportError.failed("Couldn't prepare a frame.")
                    }
                    return made
                }

                while !input.isReadyForMoreMediaData {
                    if writer.status == .failed {
                        throw VideoExportError.failed(writer.error?.localizedDescription ?? "The video stopped.")
                    }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                let time = CMTime(value: CMTimeValue(written), timescale: framesPerSecond)
                if !adaptor.append(buffer, withPresentationTime: time) {
                    throw VideoExportError.failed(writer.error?.localizedDescription ?? "Couldn't add a frame.")
                }
                written += 1
                progress(Double(written) / Double(total))
            }
            if let upcoming = upcoming { current = upcoming }
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

    // MARK: Helpers

    private static func load(_ frame: ExportFrame) async throws -> RenderSource {
        guard let picture = await PhotoService.shared.image(for: frame.asset, longEdge: 1440),
              let image = FrameRenderer.normalizedImage(picture) else {
            throw VideoExportError.failed("Couldn't load one of the photos.")
        }
        return RenderSource(image: image, fix: frame.fix)
    }

    private static func labelText(for asset: PHAsset, sprout: Date) -> String {
        guard let taken = asset.creationDate else { return "" }
        let day = DayMath.dayNumber(of: taken, sprout: sprout)
        return "Day \(day)  \u{00B7}  \(labelDate.string(from: taken))"
    }

    private static func labeled(_ picture: UIImage, label: String, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            picture.draw(in: CGRect(origin: .zero, size: size))
            guard !label.isEmpty else { return }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size.width * 0.048, weight: .semibold),
                .foregroundColor: UIColor.white,
            ]
            let text = NSAttributedString(string: label, attributes: attributes)
            let textSize = text.size()
            let margin = size.width * 0.037
            let pill = CGRect(
                x: margin,
                y: size.height - textSize.height - margin * 2.1,
                width: textSize.width + margin * 1.2,
                height: textSize.height + margin * 0.6
            )
            UIColor(white: 0, alpha: 0.55).setFill()
            UIBezierPath(roundedRect: pill, cornerRadius: pill.height / 2.4).fill()
            text.draw(at: CGPoint(x: pill.minX + margin * 0.6, y: pill.minY + margin * 0.3))
        }
    }

    private static func makeBuffer(from image: UIImage, pool: CVPixelBufferPool, width: Int, height: Int) -> CVPixelBuffer? {
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
