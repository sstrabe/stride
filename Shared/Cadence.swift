import Foundation

/// Pace and length units. Pace is kept in seconds per unit distance (8:22/mi = 502).
enum DistanceUnit: String, CaseIterable, Codable, Sendable {
    case mile, kilometer

    var meters: Double { self == .mile ? 1609.344 : 1000 }
    var paceSuffix: String { self == .mile ? "/mi" : "/km" }
    var short: String { self == .mile ? "mi" : "km" }
}

enum Pace {
    /// Speed in m/s for a pace of `seconds` per `unit`.
    static func speed(secondsPer seconds: Double, unit: DistanceUnit) -> Double {
        guard seconds > 0 else { return 0 }
        return unit.meters / seconds
    }

    /// Seconds per `unit` at `speed` m/s (nil when standing still).
    static func seconds(speed: Double, unit: DistanceUnit) -> Double? {
        guard speed > 0.3 else { return nil }
        return unit.meters / speed
    }

    /// "8:22"
    static func format(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0, seconds < 3600 else { return "–:––" }
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

enum Cadence {
    /// Steps per minute needed to cover `speed` m/s with steps of `stepLength` m.
    /// A step is one foot strike: running cadence counts both feet.
    static func required(speed: Double, stepLength: Double) -> Double {
        guard stepLength > 0 else { return 0 }
        return speed * 60 / stepLength
    }
}

/// Measures the current step length (one foot strike to the next) from cumulative distance and
/// step counts over a rolling window: Δdistance / Δsteps.
struct StepLengthEstimator {
    enum Source: String, Sendable { case gps, pedometer }

    struct Sample { var time: TimeInterval; var distance: Double; var steps: Double; var source: Source }

    var window: TimeInterval = 15
    var minSteps: Double = 12
    var plausible: ClosedRange<Double> = 0.3...2.5

    private(set) var samples: [Sample] = []

    mutating func reset() { samples.removeAll() }

    mutating func add(_ s: Sample) {
        if let last = samples.last,
           last.source != s.source || s.steps < last.steps || s.distance < last.distance || s.time <= last.time {
            samples.removeAll()          // new source or a counter reset: start over
        }
        samples.append(s)
        // keep one sample at or before the window start as the base
        while samples.count > 2, samples[1].time <= s.time - window { samples.removeFirst() }
    }

    /// Step length in metres, nil until enough steps have been seen.
    var stepLength: Double? {
        guard let a = samples.first, let b = samples.last, b.steps - a.steps >= minSteps else { return nil }
        let l = (b.distance - a.distance) / (b.steps - a.steps)
        return plausible.contains(l) ? l : nil
    }

    /// Measured speed in m/s over the window.
    var speed: Double? {
        guard let a = samples.first, let b = samples.last, b.time - a.time >= 3 else { return nil }
        return (b.distance - a.distance) / (b.time - a.time)
    }

    /// Measured cadence in steps per minute over the window.
    var cadence: Double? {
        guard let a = samples.first, let b = samples.last, b.time - a.time >= 3 else { return nil }
        return (b.steps - a.steps) / (b.time - a.time) * 60
    }
}

/// Turns the target speed and the measured step length into the click tempo. It moves the tempo
/// gently (max `slewPerSecond` spm per second) and keeps it inside `range`: the tempo feeds back
/// into how the runner moves, so a jumpy tempo would chase its own effect.
struct CadenceGovernor {
    var targetSpeed: Double
    var range: ClosedRange<Double> = 150...200
    var slewPerSecond: Double = 0.3
    private(set) var cadence: Double
    private var lastUpdate: TimeInterval?

    init(targetSpeed: Double, startCadence: Double, range: ClosedRange<Double> = 150...200) {
        self.targetSpeed = targetSpeed
        self.range = range
        self.cadence = min(max(startCadence, range.lowerBound), range.upperBound)
    }

    /// The tempo the current step length asks for, clamped but not slewed.
    func desired(stepLength: Double?) -> Double? {
        guard let stepLength else { return nil }
        let c = Cadence.required(speed: targetSpeed, stepLength: stepLength)
        return min(max(c, range.lowerBound), range.upperBound)
    }

    /// Advance to `time`; with no step length yet the tempo stays where it is.
    @discardableResult
    mutating func update(stepLength: Double?, time: TimeInterval, hold: Bool = false) -> Double {
        defer { lastUpdate = time }
        guard !hold, let want = desired(stepLength: stepLength) else { return cadence }
        let dt = lastUpdate.map { max(0, time - $0) } ?? 0
        let step = slewPerSecond * dt
        cadence += min(max(want - cadence, -step), step)
        cadence = min(max(cadence, range.lowerBound), range.upperBound)
        return cadence
    }

    /// Jump straight to the tempo (used when the target pace changes before a run).
    mutating func set(_ c: Double) { cadence = min(max(c, range.lowerBound), range.upperBound) }
}
