import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// One photo ready to draw, with the fix that lines it up.
struct RenderSource {
    let image: CIImage
    let fix: FrameFix
}

/// Draws photos onto a common canvas: lined up, color-matched, trimmed, and faded together.
final class FrameRenderer {
    static let shared = FrameRenderer()

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let backdrop = CIColor(red: 0.12, green: 0.16, blue: 0.12)

    static func normalizedImage(_ picture: UIImage) -> CIImage? {
        guard let image = CIImage(image: picture) else { return nil }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        return image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    }

    /// Picture size for a given proportion (width over height), with even numbers for video.
    static func canvasSize(aspect: CGFloat, longEdge: CGFloat) -> CGSize {
        let safe = (aspect.isFinite && aspect > 0.2 && aspect < 5) ? aspect : 0.75
        let long = (longEdge / 2).rounded() * 2
        if safe >= 1 {
            return CGSize(width: long, height: ((long / safe) / 2).rounded() * 2)
        }
        return CGSize(width: ((long * safe) / 2).rounded() * 2, height: long)
    }

    /// `mix` fades from `a` (0) to `b` (1).
    func render(
        _ a: RenderSource,
        _ b: RenderSource?,
        mix: Double,
        crop: CGRect,
        size: CGSize,
        useFixes: Bool
    ) -> UIImage? {
        let bounds = CGRect(origin: .zero, size: size)
        let first = canvas(a, crop: crop, size: size, useFixes: useFixes)
        var output = first
        if let b = b, mix > 0.001 {
            let second = canvas(b, crop: crop, size: size, useFixes: useFixes)
            if mix >= 0.999 {
                output = second
            } else {
                let filter = CIFilter.dissolveTransition()
                filter.inputImage = first
                filter.targetImage = second
                filter.time = Float(mix)
                output = filter.outputImage ?? first
            }
        }
        guard let rendered = context.createCGImage(output, from: bounds) else { return nil }
        return UIImage(cgImage: rendered)
    }

    private func canvas(_ source: RenderSource, crop: CGRect, size: CGSize, useFixes: Bool) -> CIImage {
        let bounds = CGRect(origin: .zero, size: size)
        let w = source.image.extent.width
        let h = source.image.extent.height
        var image = source.image
        let fix = useFixes ? source.fix : FrameFix()

        let gains = fix.gains
        if !gains.isIdentity {
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: pow(gains.r, 2.2), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: pow(gains.g, 2.2), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: pow(gains.b, 2.2), w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
        }

        // A photo of a different shape is fitted inside the canvas instead of stretched.
        let canvasAspect = size.width / size.height
        if abs(w / h - canvasAspect) / canvasAspect > 0.03 {
            let scale = min(size.width / w, size.height / h)
            let fit = CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(
                    translationX: (size.width - w * scale) / 2,
                    y: (size.height - h * scale) / 2
                ))
            let floor = CIImage(color: backdrop).cropped(to: bounds)
            return image.transformed(by: fit).composited(over: floor).cropped(to: bounds)
        }

        let area = useFixes ? crop : CGRect(x: 0, y: 0, width: 1, height: 1)
        let side = max(0.01, area.width)
        // Fractions of the photo are measured from the top-left; Core Image counts from the bottom-left.
        let toNorm = CGAffineTransform(a: 1 / w, b: 0, c: 0, d: -1 / h, tx: 0, ty: 1)
        let fromNorm = CGAffineTransform(
            a: size.width / side,
            b: 0,
            c: 0,
            d: -size.height / side,
            tx: -area.minX * size.width / side,
            ty: size.height + area.minY * size.height / side
        )
        let total = toNorm.concatenating(fix.transform).concatenating(fromNorm)
        return image.clampedToExtent().transformed(by: total).cropped(to: bounds)
    }
}
