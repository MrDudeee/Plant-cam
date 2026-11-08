import CoreGraphics
import Foundation

// Checks the stabilizer with made-up photos whose shift, tilt, zoom and brightness are known.

var failures = 0

func check(_ ok: Bool, _ message: String) {
    print((ok ? "PASS  " : "FAIL  ") + message)
    if !ok { failures += 1 }
}

struct Lcg {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 33) / Double(UInt64(1) << 31)
    }
}

func makeContext(_ width: Int, _ height: Int) -> CGContext {
    return CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

func makeScene(width: Int, height: Int, plant: Double, brightness: Double, transform: CGAffineTransform) -> CGImage {
    let context = makeContext(width, height)
    let w = Double(width)
    let h = Double(height)
    context.saveGState()
    context.concatenate(transform)
    context.setFillColor(CGColor(red: 0.80, green: 0.74, blue: 0.64, alpha: 1))
    context.fill(CGRect(x: -2000, y: -2000, width: 4000 + w, height: 4000 + h))
    var rng = Lcg(state: 42)
    for _ in 0..<70 {
        let x = rng.next() * w
        let y = rng.next() * h
        let rw = 8 + rng.next() * 40
        let rh = 8 + rng.next() * 40
        let tone = rng.next()
        if tone < 0.3 {
            context.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.22, alpha: 1))
        } else if tone < 0.55 {
            context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        } else if tone < 0.8 {
            context.setFillColor(CGColor(red: 0.75, green: 0.4, blue: 0.2, alpha: 1))
        } else {
            context.setFillColor(CGColor(red: 0.25, green: 0.3, blue: 0.7, alpha: 1))
        }
        context.fill(CGRect(x: x, y: y, width: rw, height: rh))
    }
    context.setFillColor(CGColor(red: 0.25, green: 0.15, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: w * 0.35, y: 0, width: w * 0.3, height: h * 0.25))
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.setLineWidth(8)
    context.stroke(CGRect(x: w * 0.2, y: h * 0.28, width: w * 0.6, height: h * 0.5))
    context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.2, alpha: 1))
    context.fillEllipse(in: CGRect(x: w / 2 - plant, y: h / 2 - plant * 1.4, width: plant * 2, height: plant * 2.8))
    context.restoreGState()
    if brightness < 1 {
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1 - brightness))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
    }
    return context.makeImage()!
}

func makeNoise(width: Int, height: Int, seed: UInt64) -> CGImage {
    let context = makeContext(width, height)
    var rng = Lcg(state: seed)
    for _ in 0..<2500 {
        let gray = rng.next()
        context.setFillColor(CGColor(red: gray, green: gray * 0.9, blue: gray * 0.8, alpha: 1))
        context.fill(CGRect(x: rng.next() * Double(width), y: rng.next() * Double(height), width: 6, height: 6))
    }
    return context.makeImage()!
}

/// Draws `image` into a same-sized canvas with a fix given in fractions of the photo,
/// measured from the top-left (the same convention the app's renderer uses).
func warp(_ image: CGImage, by normalized: CGAffineTransform, width: Int, height: Int) -> CGImage {
    let context = makeContext(width, height)
    let w = CGFloat(width)
    let h = CGFloat(height)
    let toNorm = CGAffineTransform(a: 1 / w, b: 0, c: 0, d: -1 / h, tx: 0, ty: 1)
    let fromNorm = CGAffineTransform(a: w, b: 0, c: 0, d: -h, tx: 0, ty: h)
    context.concatenate(toNorm.concatenating(normalized).concatenating(fromNorm))
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return context.makeImage()!
}

func readPixels(_ image: CGImage) -> (w: Int, h: Int, rgba: [UInt8]) {
    let w = image.width
    let h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    data.withUnsafeMutableBytes { raw in
        let context = CGContext(
            data: raw.baseAddress,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return (w, h, data)
}

/// Brightness with the average removed, plus which pixels count (opaque and not green).
func zscores(_ p: (w: Int, h: Int, rgba: [UInt8])) -> (z: [Float], ok: [Bool]) {
    let n = p.w * p.h
    var lum = [Float](repeating: 0, count: n)
    var ok = [Bool](repeating: false, count: n)
    var sum = 0.0
    var sumSq = 0.0
    var count = 0
    for i in 0..<n {
        let r = Float(p.rgba[i * 4])
        let g = Float(p.rgba[i * 4 + 1])
        let b = Float(p.rgba[i * 4 + 2])
        let a = p.rgba[i * 4 + 3]
        let l = 0.299 * r + 0.587 * g + 0.114 * b
        lum[i] = l
        if a > 250 && g - max(r, b) <= 8 {
            ok[i] = true
            sum += Double(l)
            sumSq += Double(l * l)
            count += 1
        }
    }
    let mean = sum / Double(max(count, 1))
    let std = max(1.0, max(0, sumSq / Double(max(count, 1)) - mean * mean).squareRoot())
    var z = [Float](repeating: 0, count: n)
    for i in 0..<n where ok[i] {
        z[i] = Float((Double(lum[i]) - mean) / std)
    }
    return (z, ok)
}

/// Average difference between the two photos' backgrounds. Lower means better lined up.
func difference(_ a: CGImage, _ b: CGImage) -> Double {
    let pa = readPixels(a)
    let pb = readPixels(b)
    let za = zscores(pa)
    let zb = zscores(pb)
    var sum = 0.0
    var count = 0
    for i in 0..<(pa.w * pa.h) where za.ok[i] && zb.ok[i] {
        sum += Double(abs(za.z[i] - zb.z[i]))
        count += 1
    }
    return count > 0 ? sum / Double(count) : 99
}

func isNearIdentity(_ t: CGAffineTransform) -> Bool {
    return abs(t.a - 1) < 0.002 && abs(t.d - 1) < 0.002 && abs(t.b) < 0.002 && abs(t.c) < 0.002
        && abs(t.tx) < 0.003 && abs(t.ty) < 0.003
}

func fmt(_ value: Double) -> String {
    return String(format: "%.3f", value)
}

let W = 480
let H = 640
let center = CGPoint(x: Double(W) / 2, y: Double(H) / 2)

func shake(dx: Double, dy: Double, degrees: Double, scale: Double) -> CGAffineTransform {
    return CGAffineTransform.identity
        .translatedBy(x: center.x + dx, y: center.y + dy)
        .rotated(by: degrees * Double.pi / 180)
        .scaledBy(x: scale, y: scale)
        .translatedBy(x: -center.x, y: -center.y)
}

print("== Stabilizer checks ==")

let reference = makeScene(width: W, height: H, plant: 60, brightness: 1, transform: .identity)
guard let session = StabilizerSession(reference: reference) else {
    print("FAIL  couldn't prepare the reference photo")
    exit(1)
}

// A. Shifted, tilted and zoomed, dimmer, with a smaller plant.
let floatingA = makeScene(width: W, height: H, plant: 40, brightness: 0.85,
                          transform: shake(dx: 18, dy: -12, degrees: 3, scale: 1.04))
let fixA = session.fix(for: floatingA)
let beforeA = difference(floatingA, reference)
let afterA = difference(warp(floatingA, by: fixA.transform, width: W, height: H), reference)
print("A: before " + fmt(beforeA) + ", after " + fmt(afterA))
print("A note: " + fixA.note)
check(fixA.aligned, "A: found a fix for shift + tilt + zoom")
check(afterA < beforeA * 0.5, "A: background difference at least halves")
check(fixA.gains.r > 1.1 && fixA.gains.g > 1.1 && fixA.gains.b > 1.1, "A: brightens the dim photo")

// B. A plain small shift.
let floatingB = makeScene(width: W, height: H, plant: 50, brightness: 1,
                          transform: shake(dx: 6, dy: 4, degrees: 0, scale: 1))
let fixB = session.fix(for: floatingB)
let beforeB = difference(floatingB, reference)
let afterB = difference(warp(floatingB, by: fixB.transform, width: W, height: H), reference)
print("B: before " + fmt(beforeB) + ", after " + fmt(afterB))
print("B note: " + fixB.note)
check(fixB.aligned, "B: found a fix for a small shift")
check(afterB < beforeB * 0.5, "B: background difference at least halves")

// C. The same photo again should stay put.
let fixC = session.fix(for: reference)
print("C note: " + fixC.note)
check(isNearIdentity(fixC.transform), "C: an identical photo isn't moved")

// D. A photo with nothing to line up shouldn't be moved.
let noiseRef = makeNoise(width: W, height: H, seed: 7)
let noiseSession = StabilizerSession(reference: noiseRef)
let fixD = noiseSession?.fix(for: makeNoise(width: W, height: H, seed: 99))
print("D note: " + (fixD?.note ?? "no session"))
check(fixD == nil || !(fixD!.aligned) || isNearIdentity(fixD!.transform), "D: unrelated noise isn't forced into place")

// E. A photo of a different shape is left alone.
let odd = makeScene(width: 300, height: 300, plant: 40, brightness: 1, transform: .identity)
let fixE = session.fix(for: odd)
print("E note: " + fixE.note)
check(isNearIdentity(fixE.transform) && !fixE.aligned, "E: a different-shaped photo isn't moved")

// F. The crop stays inside sensible bounds.
let crop = Stabilizer.crop(for: [session.referenceFix(), fixA, fixB])
print("F: crop x " + fmt(Double(crop.minX)) + " y " + fmt(Double(crop.minY)) + " size " + fmt(Double(crop.width)) + " x " + fmt(Double(crop.height)))
check(crop.minX >= 0 && crop.minY >= 0 && crop.maxX <= 1 && crop.maxY <= 1, "F: crop stays inside the photo")
check(crop.width >= 0.8 && abs(crop.width - crop.height) < 0.0001, "F: crop keeps the proportions and loses under 20%")

// Pacing.
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(secondsFromGMT: 0)!
let base = Date(timeIntervalSince1970: 1_790_000_000)
let start = calendar.startOfDay(for: base)
func stamp(day: Int, hour: Int) -> Date {
    return start.addingTimeInterval(Double(day) * 86_400 + Double(hour) * 3_600)
}

let smartDays: [Date?] = [
    stamp(day: 0, hour: 17), stamp(day: 1, hour: 17), stamp(day: 2, hour: 17),
    stamp(day: 3, hour: 9), stamp(day: 3, hour: 18), stamp(day: 4, hour: 17),
    stamp(day: 8, hour: 17), stamp(day: 9, hour: 17), stamp(day: 10, hour: 17), stamp(day: 11, hour: 17),
]
let planA = Pacing.plan(dates: smartDays, smart: true, calendar: calendar)
print("Pacing: " + planA.map { "\($0.index):" + fmt($0.weight) }.joined(separator: " "))
check(planA.count == 9, "Pacing: one photo per day (9 days from 10 photos)")
check(planA.contains(where: { $0.index == 4 }) && !planA.contains(where: { $0.index == 3 }), "Pacing: keeps the photo closest to the usual time of day")
check(planA.first(where: { $0.index == 5 })?.weight == 2.05, "Pacing: a 4-day gap lingers (weight 2.05)")
check(planA.first(where: { $0.index == 0 })?.weight == 1, "Pacing: daily photos get the normal pace")

let fewDays: [Date?] = (0..<8).map { stamp(day: $0 / 4, hour: 9 + $0) }
let planB = Pacing.plan(dates: fewDays, smart: true, calendar: calendar)
check(planB.count == 8, "Pacing: with only 2 days, every photo is shown")

let planC = Pacing.plan(dates: smartDays, smart: false, calendar: calendar)
check(planC.count == 10 && planC.allSatisfy { $0.weight == 1 }, "Pacing: even mode shows every photo at the same pace")

print("== " + String(failures) + " check(s) failed ==")
exit(failures == 0 ? 0 : 1)
