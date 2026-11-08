import Foundation

struct PacedFrame: Equatable {
    /// Position in the original photo list.
    let index: Int
    /// How long this photo's transition lasts compared with a normal one (1 = normal).
    let weight: Double
}

enum Pacing {
    /// Smart pacing shows one photo per day (the one shot closest to the usual time of day,
    /// so the light matches) and gives longer gaps a little more time. With fewer than six
    /// different days it shows every photo, since there isn't enough to thin out.
    static func plan(dates: [Date?], smart: Bool, calendar: Calendar = .current) -> [PacedFrame] {
        let everyPhoto = dates.indices.map { PacedFrame(index: $0, weight: 1) }
        guard smart else { return everyPhoto }

        var known: [(index: Int, date: Date)] = []
        for (i, maybe) in dates.enumerated() {
            guard let date = maybe else { return everyPhoto }
            known.append((i, date))
        }

        var groups: [(day: Date, items: [(index: Int, date: Date)])] = []
        for item in known {
            let day = calendar.startOfDay(for: item.date)
            if let last = groups.last, last.day == day {
                groups[groups.count - 1].items.append(item)
            } else {
                groups.append((day, [item]))
            }
        }
        if groups.count < 6 { return everyPhoto }

        func minutes(_ date: Date) -> Double {
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
        }
        let sorted = known.map { minutes($0.date) }.sorted()
        let usual = sorted[sorted.count / 2]

        var picks: [(index: Int, day: Date)] = []
        for group in groups {
            guard let best = group.items.min(by: {
                abs(minutes($0.date) - usual) < abs(minutes($1.date) - usual)
            }) else { continue }
            picks.append((best.index, group.day))
        }

        var result: [PacedFrame] = []
        for (k, pick) in picks.enumerated() {
            var weight = 1.0
            if k + 1 < picks.count {
                let gap = max(1, calendar.dateComponents([.day], from: pick.day, to: picks[k + 1].day).day ?? 1)
                weight = 1 + 0.35 * Double(min(gap, 8) - 1)
            }
            result.append(PacedFrame(index: pick.index, weight: weight))
        }
        return result
    }
}
