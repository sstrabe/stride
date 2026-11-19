import Foundation

/// Your usual step length at a given speed, from past runs in Apple Health (running stride length
/// paired with running speed). Step length grows with speed, so a line through (speed, stride) gives
/// a better start than one average.
enum StrideFit {
    struct Point: Equatable, Sendable { var speed: Double; var stride: Double }

    struct Estimate: Equatable, Sendable {
        var stride: Double
        var samples: Int
        var bySpeed: Bool      // from the speed line, not the plain median
    }

    static let plausibleStride = 0.4...2.2      // m per step
    static let plausibleSpeed = 1.5...7.0       // m/s (about 3:50 to 17:50 per mile)

    /// - points: (speed, stride) pairs; `strides`: stride samples without a speed partner.
    static func estimate(at speed: Double, points: [Point], strides: [Double] = []) -> Estimate? {
        let pts = points.filter { plausibleStride.contains($0.stride) && plausibleSpeed.contains($0.speed) }
        if pts.count >= 20 {
            let n = Double(pts.count)
            let mx = pts.map(\.speed).reduce(0, +) / n
            let my = pts.map(\.stride).reduce(0, +) / n
            let sxx = pts.map { ($0.speed - mx) * ($0.speed - mx) }.reduce(0, +)
            let sxy = pts.map { ($0.speed - mx) * ($0.stride - my) }.reduce(0, +)
            let spread = (sxx / n).squareRoot()
            if spread >= 0.15 && sxx > 0 {
                let slope = sxy / sxx
                // don't extrapolate far beyond the speeds actually run
                let lo = pts.map(\.speed).min()! - 0.5, hi = pts.map(\.speed).max()! + 0.5
                let v = min(max(speed, lo), hi)
                let s = my + slope * (v - mx)
                if plausibleStride.contains(s) { return Estimate(stride: s, samples: pts.count, bySpeed: true) }
            }
        }
        let all = (pts.map(\.stride) + strides.filter { plausibleStride.contains($0) }).sorted()
        guard all.count >= 5 else { return nil }
        let mid = all.count / 2
        let median = all.count % 2 == 1 ? all[mid] : (all[mid - 1] + all[mid]) / 2
        return Estimate(stride: median, samples: all.count, bySpeed: false)
    }

    /// Pairs each stride sample with the speed sample nearest in time (within `maxGap` seconds).
    /// Inputs are (sample midpoint, value) and need not be sorted.
    static func pair(strides: [(Date, Double)], speeds: [(Date, Double)], maxGap: TimeInterval = 30)
        -> (points: [Point], unpaired: [Double]) {
        let sp = speeds.sorted { $0.0 < $1.0 }
        var points: [Point] = [], unpaired: [Double] = []
        for (t, s) in strides {
            var lo = 0, hi = sp.count
            while lo < hi { let m = (lo + hi) / 2; if sp[m].0 < t { lo = m + 1 } else { hi = m } }
            var best: (TimeInterval, Double)?
            for i in [lo - 1, lo] where i >= 0 && i < sp.count {
                let gap = abs(sp[i].0.timeIntervalSince(t))
                if gap <= maxGap, best == nil || gap < best!.0 { best = (gap, sp[i].1) }
            }
            if let best { points.append(Point(speed: best.1, stride: s)) } else { unpaired.append(s) }
        }
        return (points, unpaired)
    }
}
