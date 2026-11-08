import CoreGraphics
import Foundation
import Vision
import simd

// MARK: - What the stabilizer hands back

struct StabGains {
    var r: CGFloat = 1
    var g: CGFloat = 1
    var b: CGFloat = 1

    var isIdentity: Bool {
        abs(r - 1) < 0.001 && abs(g - 1) < 0.001 && abs(b - 1) < 0.001
    }
}

/// How to correct one photo so it lines up with the reference photo.
struct FrameFix {
    /// Moves this photo's coordinates (0...1 across, 0...1 down from the top-left)
    /// onto the reference photo's.
    var transform: CGAffineTransform = .identity
    /// Multipliers that bring this photo's background color to the reference's.
    var gains = StabGains()
    /// True when a better position was found (or this is the reference itself).
    var aligned = false
    var note = ""
}

/// A grid of brightness values for the background of a photo.
struct StabField {
    let width: Int
    let height: Int
    /// Brightness with the average removed. Plant pixels are 0.
    let gray: [Float]
    /// True where the pixel is background (not green).
    let valid: [Bool]

    /// Half the size, averaging the background pixels in each 2x2 block.
    func halved() -> StabField {
        let w = max(1, width / 2)
        let h = max(1, height / 2)
        var g = [Float](repeating: 0, count: w * h)
        var v = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var sum: Float = 0
                var n = 0
                for dy in 0..<2 {
                    for dx in 0..<2 {
                        let sx = min(width - 1, x * 2 + dx)
                        let sy = min(height - 1, y * 2 + dy)
                        let i = sy * width + sx
                        if valid[i] {
                            sum += gray[i]
                            n += 1
                        }
                    }
                }
                if n >= 2 {
                    g[y * w + x] = sum / Float(n)
                    v[y * w + x] = true
                }
            }
        }
        return StabField(width: w, height: h, gray: g, valid: v)
    }
}

/// A small, plant-free copy of a photo, used only to work out the alignment.
struct StabPrepared {
    let field: StabField
    let meanRGB: SIMD3<Float>
    let usable: Bool
    let visionImage: CGImage

    var width: Int { field.width }
    var height: Int { field.height }
}

/// Shift, turn and zoom about the middle of the photo, in pixels and radians.
fileprivate struct StabParams {
    var dx: CGFloat
    var dy: CGFloat
    var rot: CGFloat
    var scale: CGFloat

    init(dx: CGFloat = 0, dy: CGFloat = 0, rot: CGFloat = 0, scale: CGFloat = 1) {
        self.dx = dx
        self.dy = dy
        self.rot = rot
        self.scale = scale
    }

    init(from t: CGAffineTransform, center c: CGPoint) {
        let moved = c.applying(t)
        self.init(dx: moved.x - c.x, dy: moved.y - c.y, rot: atan2(t.b, t.a), scale: hypot(t.a, t.b))
    }

    func transform(center c: CGPoint) -> CGAffineTransform {
        let cosv = cos(rot) * scale
        let sinv = sin(rot) * scale
        let tx = c.x + dx - (cosv * c.x - sinv * c.y)
        let ty = c.y + dy - (sinv * c.x + cosv * c.y)
        return CGAffineTransform(a: cosv, b: sinv, c: -sinv, d: cosv, tx: tx, ty: ty)
    }
}

// MARK: - One run of the stabilizer

/// Lines photos up with one reference photo using only what holds still (the pot, the ring,
/// the wall) and ignoring the plant. Make one per timelapse, then call `fix(for:)` per photo.
final class StabilizerSession {
    private let reference: StabPrepared

    init?(reference image: CGImage) {
        guard let prepared = Stabilizer.prepare(image), prepared.usable else { return nil }
        reference = prepared
    }

    func referenceFix() -> FrameFix {
        var fix = FrameFix()
        fix.aligned = true
        fix.note = "reference"
        return fix
    }

    func fix(for image: CGImage) -> FrameFix {
        var fix = FrameFix()
        guard let floating = Stabilizer.prepare(image) else {
            fix.note = "couldn't read the photo"
            return fix
        }
        guard floating.width == reference.width, floating.height == reference.height else {
            fix.note = "different shape from the reference"
            return fix
        }
        fix.gains = Stabilizer.gains(floating: floating, reference: reference)
        guard floating.usable else {
            fix.note = "too little background to line up"
            return fix
        }
        guard let unmoved = Stabilizer.score(
            floating: floating.field,
            reference: reference.field,
            transform: .identity,
            stride: 2
        ) else {
            fix.note = "not enough overlap"
            return fix
        }

        let w = floating.width
        let h = floating.height
        let center = CGPoint(x: Double(w) / 2, y: Double(h) / 2)

        // Vision's answer is only a starting point. Pick whichever reading of it
        // lines the backgrounds up best, or start from "no move".
        let found = Stabilizer.registrations(floating: floating.visionImage, reference: reference.visionImage)
        let options = Stabilizer.candidates(homography: found.homography, translation: found.translation, width: w, height: h)
        var seed = StabParams()
        var seedScore = unmoved.mse
        var seedIndex = -1
        for (n, option) in options.enumerated() {
            let params = StabParams(from: option, center: center)
            guard Stabilizer.isSane(params, width: w, height: h),
                  let value = Stabilizer.score(
                    floating: floating.field,
                    reference: reference.field,
                    transform: params.transform(center: center),
                    stride: 2
                  ),
                  value.coverage >= Stabilizer.minCoverage,
                  value.mse < seedScore else { continue }
            seed = params
            seedScore = value.mse
            seedIndex = n
        }

        guard let refined = Stabilizer.refine(floating: floating.field, reference: reference.field, from: seed) else {
            fix.note = "couldn't fine-tune"
            return fix
        }
        let p = refined.params
        let vision = found.homography != nil ? "yes" : "no"
        let summary = "seed #\(seedIndex) (\(seedScore)), unmoved \(unmoved.mse), final \(refined.mse), "
            + "dx \(p.dx) dy \(p.dy) rot \(p.rot) scale \(p.scale), vision \(vision)"

        if refined.mse < unmoved.mse * Stabilizer.minImprovement {
            fix.transform = Stabilizer.normalize(p.transform(center: center), width: w, height: h)
            fix.aligned = true
            fix.note = "moved: " + summary
        } else if unmoved.mse < Stabilizer.alreadyAligned {
            fix.aligned = true
            fix.note = "already in place: " + summary
        } else {
            fix.note = "kept as shot: " + summary
        }
        return fix
    }
}

// MARK: - The work

enum Stabilizer {
    static let workEdge = 320
    fileprivate static let minImprovement = 0.9
    fileprivate static let alreadyAligned = 0.05
    fileprivate static let minCoverage = 0.6
    fileprivate static let maxScaleChange = 0.2
    fileprivate static let maxRotation = 15.0 * Double.pi / 180.0
    fileprivate static let maxShift: CGFloat = 0.3

    /// Shrinks a photo, flattens the green (the plant) and removes the average brightness.
    static func prepare(_ image: CGImage) -> StabPrepared? {
        let longest = max(image.width, image.height)
        guard longest > 0 else { return nil }
        let scale = Double(workEdge) / Double(longest)
        let w = max(8, Int((Double(image.width) * scale).rounded()))
        let h = max(8, Int((Double(image.height) * scale).rounded()))

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        let count = w * h
        var lum = [Float](repeating: 0, count: count)
        var valid = [Bool](repeating: false, count: count)
        var sumL = 0.0, sumLL = 0.0, sumR = 0.0, sumG = 0.0, sumB = 0.0
        var n = 0
        for i in 0..<count {
            let r = Float(pixels[i * 4])
            let g = Float(pixels[i * 4 + 1])
            let b = Float(pixels[i * 4 + 2])
            let l = 0.299 * r + 0.587 * g + 0.114 * b
            lum[i] = l
            if g - max(r, b) <= 8 {
                valid[i] = true
                sumL += Double(l)
                sumLL += Double(l * l)
                sumR += Double(r)
                sumG += Double(g)
                sumB += Double(b)
                n += 1
            }
        }
        let usable = n > count / 4
        let denom = Double(max(n, 1))
        let mean = sumL / denom
        let variance = max(0, sumLL / denom - mean * mean)
        let std = max(1.0, variance.squareRoot())

        var gray = [Float](repeating: 0, count: count)
        var bytes = [UInt8](repeating: 128, count: count)
        for i in 0..<count where valid[i] {
            let z = Float((Double(lum[i]) - mean) / std)
            gray[i] = z
            bytes[i] = UInt8(max(0, min(255, 128 + 48 * z)))
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let visionImage = CGImage(
                width: w,
                height: h,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }

        return StabPrepared(
            field: StabField(width: w, height: h, gray: gray, valid: valid),
            meanRGB: SIMD3<Float>(Float(sumR / denom), Float(sumG / denom), Float(sumB / denom)),
            usable: usable,
            visionImage: visionImage
        )
    }

    fileprivate static func gains(floating f: StabPrepared, reference r: StabPrepared) -> StabGains {
        func ratio(_ target: Float, _ own: Float) -> CGFloat {
            guard own > 1 else { return 1 }
            let value = min(1.33, max(0.75, CGFloat(target / own)))
            return abs(value - 1) < 0.02 ? 1 : value
        }
        return StabGains(
            r: ratio(r.meanRGB.x, f.meanRGB.x),
            g: ratio(r.meanRGB.y, f.meanRGB.y),
            b: ratio(r.meanRGB.z, f.meanRGB.z)
        )
    }

    // MARK: Asking Vision

    fileprivate static func registrations(
        floating: CGImage,
        reference: CGImage
    ) -> (homography: simd_float3x3?, translation: CGAffineTransform?) {
        var homography: simd_float3x3?
        var translation: CGAffineTransform?
        let handler = VNImageRequestHandler(cgImage: reference, options: [:])

        let homographic = VNHomographicImageRegistrationRequest(targetedCGImage: floating, options: [:])
        do {
            try handler.perform([homographic])
            if let observation = homographic.results?.first as? VNImageHomographicAlignmentObservation {
                homography = observation.warpTransform
            }
        } catch {}

        let translational = VNTranslationalImageRegistrationRequest(targetedCGImage: floating, options: [:])
        do {
            try handler.perform([translational])
            if let observation = translational.results?.first as? VNImageTranslationAlignmentObservation {
                translation = observation.alignmentTransform
            }
        } catch {}

        return (homography, translation)
    }

    // MARK: Reading Vision's answer

    /// Vision doesn't say which way its numbers point (pixels or fractions, top or bottom,
    /// forwards or backwards), so this builds every reading and lets the scoring pick.
    fileprivate static func candidates(
        homography: simd_float3x3?,
        translation: CGAffineTransform?,
        width w: Int,
        height h: Int
    ) -> [CGAffineTransform] {
        var out: [CGAffineTransform] = []
        let fw = CGFloat(w)
        let fh = CGFloat(h)

        if let base = homography {
            var matrices: [simd_float3x3] = [base, base.transpose]
            if abs(base.determinant) > 1e-12 {
                matrices.append(base.inverse)
                matrices.append(base.transpose.inverse)
            }
            var grid: [CGPoint] = []
            for j in 0...4 {
                for i in 0...4 {
                    grid.append(CGPoint(x: fw * CGFloat(i) / 4, y: fh * CGFloat(j) / 4))
                }
            }
            for matrix in matrices {
                for space in 0..<4 {
                    var mapped: [CGPoint] = []
                    var ok = true
                    for p in grid {
                        let input: SIMD3<Float>
                        switch space {
                        case 0: input = SIMD3<Float>(Float(p.x), Float(p.y), 1)
                        case 1: input = SIMD3<Float>(Float(p.x), Float(fh - p.y), 1)
                        case 2: input = SIMD3<Float>(Float(p.x / fw), Float(p.y / fh), 1)
                        default: input = SIMD3<Float>(Float(p.x / fw), Float(1 - p.y / fh), 1)
                        }
                        let q = matrix * input
                        if !q.z.isFinite || abs(q.z) < 1e-9 {
                            ok = false
                            break
                        }
                        let x = CGFloat(q.x / q.z)
                        let y = CGFloat(q.y / q.z)
                        switch space {
                        case 0: mapped.append(CGPoint(x: x, y: y))
                        case 1: mapped.append(CGPoint(x: x, y: fh - y))
                        case 2: mapped.append(CGPoint(x: x * fw, y: y * fh))
                        default: mapped.append(CGPoint(x: x * fw, y: (1 - y) * fh))
                        }
                    }
                    if ok, let fit = fitSimilarity(from: grid, to: mapped) {
                        out.append(fit)
                    }
                }
            }
        }

        if let shift = translation {
            let scales: [(CGFloat, CGFloat)] = [(1, 1), (fw, fh)]
            let signs: [(CGFloat, CGFloat)] = [(1, 1), (-1, -1), (1, -1), (-1, 1)]
            for scale in scales {
                for sign in signs {
                    out.append(CGAffineTransform(
                        translationX: shift.tx * scale.0 * sign.0,
                        y: shift.ty * scale.1 * sign.1
                    ))
                }
            }
        }
        return out
    }

    /// The shift, turn and zoom that best carries `src` onto `dst`.
    fileprivate static func fitSimilarity(from src: [CGPoint], to dst: [CGPoint]) -> CGAffineTransform? {
        guard src.count == dst.count, src.count >= 2 else { return nil }
        let n = CGFloat(src.count)
        let pc = CGPoint(x: src.map { $0.x }.reduce(0, +) / n, y: src.map { $0.y }.reduce(0, +) / n)
        let qc = CGPoint(x: dst.map { $0.x }.reduce(0, +) / n, y: dst.map { $0.y }.reduce(0, +) / n)
        var dot: CGFloat = 0
        var cross: CGFloat = 0
        var den: CGFloat = 0
        for k in src.indices {
            let ax = src[k].x - pc.x
            let ay = src[k].y - pc.y
            let bx = dst[k].x - qc.x
            let by = dst[k].y - qc.y
            dot += ax * bx + ay * by
            cross += ax * by - ay * bx
            den += ax * ax + ay * ay
        }
        guard den > 1e-9 else { return nil }
        let c = dot / den
        let s = cross / den
        guard c.isFinite, s.isFinite else { return nil }
        let tx = qc.x - (c * pc.x - s * pc.y)
        let ty = qc.y - (s * pc.x + c * pc.y)
        return CGAffineTransform(a: c, b: s, c: -s, d: c, tx: tx, ty: ty)
    }

    fileprivate static func isSane(_ p: StabParams, width w: Int, height h: Int) -> Bool {
        guard p.scale.isFinite, p.rot.isFinite, p.dx.isFinite, p.dy.isFinite else { return false }
        return abs(p.scale - 1) <= CGFloat(maxScaleChange)
            && abs(p.rot) <= CGFloat(maxRotation)
            && abs(p.dx) <= maxShift * CGFloat(w)
            && abs(p.dy) <= maxShift * CGFloat(h)
    }

    // MARK: Fine-tuning

    /// Nudges shift, turn and zoom until the backgrounds line up as well as they can. It starts
    /// on a small blurry copy (where a wrong guess is easy to fix) and finishes on sharper ones.
    fileprivate static func refine(
        floating f: StabField,
        reference r: StabField,
        from seed: StabParams
    ) -> (params: StabParams, mse: Double)? {
        var levels: [(StabField, StabField)] = [(f, r)]
        for _ in 0..<2 {
            guard let last = levels.last, last.0.width >= 80 else { break }
            levels.append((last.0.halved(), last.1.halved()))
        }

        var params = seed
        var finalScore: Double?
        for (n, level) in levels.enumerated().reversed() {
            let factor = CGFloat(1 << n)
            let lf = level.0
            let lr = level.1
            let stride = n == 0 ? 2 : 1
            let center = CGPoint(x: Double(lf.width) / 2, y: Double(lf.height) / 2)

            func cost(_ p: StabParams) -> Double? {
                guard isSane(p, width: lf.width, height: lf.height) else { return nil }
                guard let s = score(floating: lf, reference: lr, transform: p.transform(center: center), stride: stride),
                      s.coverage >= minCoverage else { return nil }
                return s.mse
            }

            var current = StabParams(dx: params.dx / factor, dy: params.dy / factor, rot: params.rot, scale: params.scale)
            guard var best = cost(current) else { continue }
            var stepXY: CGFloat = n == 2 ? 3 : (n == 1 ? 1.5 : 1)
            var stepRot: CGFloat = n == 2 ? 0.02 : (n == 1 ? 0.008 : 0.003)
            var stepScale: CGFloat = n == 2 ? 0.02 : (n == 1 ? 0.008 : 0.003)
            var passes = 0
            while passes < 40 {
                passes += 1
                var improved = false
                for k in 0..<8 {
                    var trial = current
                    switch k {
                    case 0: trial.dx += stepXY
                    case 1: trial.dx -= stepXY
                    case 2: trial.dy += stepXY
                    case 3: trial.dy -= stepXY
                    case 4: trial.rot += stepRot
                    case 5: trial.rot -= stepRot
                    case 6: trial.scale += stepScale
                    default: trial.scale -= stepScale
                    }
                    if let c = cost(trial), c < best - 1e-9 {
                        best = c
                        current = trial
                        improved = true
                    }
                }
                if !improved {
                    stepXY /= 2
                    stepRot /= 2
                    stepScale /= 2
                    if stepXY < 0.1 { break }
                }
            }
            params = StabParams(dx: current.dx * factor, dy: current.dy * factor, rot: current.rot, scale: current.scale)
            finalScore = best
        }
        guard let result = finalScore else { return nil }
        return (params, result)
    }

    // MARK: Scoring

    /// How different the two backgrounds look once `t` (pixels, photo onto reference) is applied.
    /// Lower is better. Also reports how much of the reference's background it covers.
    /// Nil when too little of the two overlap.
    fileprivate static func score(
        floating f: StabField,
        reference r: StabField,
        transform t: CGAffineTransform,
        stride: Int
    ) -> (mse: Double, coverage: Double)? {
        let det = t.a * t.d - t.b * t.c
        guard abs(det) > 1e-6 else { return nil }
        let inv = t.inverted()
        let w = r.width
        let h = r.height
        var sum = 0.0
        var count = 0
        var refValid = 0
        var total = 0
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                total += 1
                let idx = y * w + x
                if r.valid[idx] {
                    refValid += 1
                    let fx = CGFloat(x)
                    let fy = CGFloat(y)
                    let sx = inv.a * fx + inv.c * fy + inv.tx
                    let sy = inv.b * fx + inv.d * fy + inv.ty
                    if sx >= 0, sy >= 0, sx < CGFloat(w - 1), sy < CGFloat(h - 1) {
                        let nx = Int(sx.rounded())
                        let ny = Int(sy.rounded())
                        if f.valid[ny * w + nx] {
                            let value = bilinear(f.gray, w, sx, sy)
                            let d = Double(r.gray[idx] - value)
                            sum += d * d
                            count += 1
                        }
                    }
                }
                x += stride
            }
            y += stride
        }
        guard count > total / 4, refValid > 0 else { return nil }
        return (sum / Double(count), Double(count) / Double(refValid))
    }

    private static func bilinear(_ g: [Float], _ w: Int, _ x: CGFloat, _ y: CGFloat) -> Float {
        let x0 = Int(x)
        let y0 = Int(y)
        let fx = Float(x - CGFloat(x0))
        let fy = Float(y - CGFloat(y0))
        let i = y0 * w + x0
        let top = g[i] * (1 - fx) + g[i + 1] * fx
        let bottom = g[i + w] * (1 - fx) + g[i + w + 1] * fx
        return top * (1 - fy) + bottom * fy
    }

    /// Pixels to fractions of the photo, so one fix works at any size.
    fileprivate static func normalize(_ t: CGAffineTransform, width w: Int, height h: Int) -> CGAffineTransform {
        let up = CGAffineTransform(scaleX: CGFloat(w), y: CGFloat(h))
        let down = CGAffineTransform(scaleX: 1 / CGFloat(w), y: 1 / CGFloat(h))
        return up.concatenating(t).concatenating(down)
    }

    // MARK: Cropping

    /// The part of the reference photo that every aligned photo covers, kept in the photo's
    /// proportions. Fractions of the width and height, measured from the top-left.
    static func crop(for fixes: [FrameFix], maxInset: CGFloat = 0.1) -> CGRect {
        var left: CGFloat = 0
        var right: CGFloat = 0
        var top: CGFloat = 0
        var bottom: CGFloat = 0
        for fix in fixes where fix.aligned {
            let corners = [
                CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1),
            ].map { $0.applying(fix.transform) }
            left = max(left, corners[0].x, corners[2].x)
            right = max(right, 1 - corners[1].x, 1 - corners[3].x)
            top = max(top, corners[0].y, corners[1].y)
            bottom = max(bottom, 1 - corners[2].y, 1 - corners[3].y)
        }
        left = min(maxInset, max(0, left))
        right = min(maxInset, max(0, right))
        top = min(maxInset, max(0, top))
        bottom = min(maxInset, max(0, bottom))
        let cw = 1 - left - right
        let ch = 1 - top - bottom
        let s = max(0.5, min(cw, ch))
        return CGRect(x: left + (cw - s) / 2, y: top + (ch - s) / 2, width: s, height: s)
    }
}
