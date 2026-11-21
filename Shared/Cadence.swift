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
    enum Source: String, Sendable { case gps, pedometer, watch }

    struct Sample { var time: TimeInterval; var distance: Double; var steps: Double; var source: Source }

    var window: TimeInterval = 20
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

/// A goal distance at the target pace: the speed the rest of the run needs so the whole
/// distance comes in at the target pace's total time. Behind schedule it asks for a bit more,
/// ahead a bit less, within `band` of the target speed (it never asks for a sprint).
enum GoalPace {
    static let band = 0.12

    /// Seconds behind the target pace's schedule at this point (negative: ahead).
    static func behind(distance: Double, elapsed: TimeInterval, targetSpeed: Double) -> Double {
        guard targetSpeed > 0 else { return 0 }
        return elapsed - distance / targetSpeed
    }

    /// The speed to aim for now; the plain target once the goal is reached (or with no goal).
    static func speed(goal: Double?, distance: Double, elapsed: TimeInterval, targetSpeed: Double) -> Double {
        guard let goal, goal > 0, distance < goal, targetSpeed > 0 else { return targetSpeed }
        let timeLeft = goal / targetSpeed - elapsed
        let lo = targetSpeed * (1 - band), hi = targetSpeed * (1 + band)
        guard timeLeft > 1 else { return hi }
        return min(max((goal - distance) / timeLeft, lo), hi)
    }
}

/// Easy runs by heart rate: the speed to aim for drifts down while the heart rate is over the
/// ceiling and up while it is well under it (heart rate lags the effort by half a minute or
/// more, so it moves slowly). If the click is already at its lowest and the heart rate stays
/// over the ceiling, it calls for a walk until the heart rate is back well under.
struct HeartRateGovernor: Sendable {
    var ceiling: Double
    /// Aim for this band under the ceiling.
    var band: Double = 6
    var minSpeed = 1.0, maxSpeed = 5.0
    /// m/s per second per bpm out of the band (down twice as fast as up).
    var gain = 0.0006
    var walkAfter: TimeInterval = 30
    var walkOver: Double = 5
    var resumeUnder: Double = 12

    private(set) var speed: Double
    private(set) var walking = false
    private var lastTime: TimeInterval?
    private var overSince: TimeInterval?

    init(ceiling: Double, startSpeed: Double) {
        self.ceiling = ceiling
        self.speed = startSpeed
    }

    /// `atFloor`: the click is at its lowest tempo, so slowing the click can't slow the run.
    @discardableResult
    mutating func update(heartRate hr: Double?, time: TimeInterval, atFloor: Bool) -> Double {
        let dt = lastTime.map { min(max(0, time - $0), 5) } ?? 0
        lastTime = time
        guard let hr else { return speed }
        if hr > ceiling { speed -= 2 * gain * (hr - ceiling) * dt }
        else if hr < ceiling - band { speed += gain * (ceiling - band - hr) * dt }
        speed = min(max(speed, minSpeed), maxSpeed)

        if walking {
            if hr <= ceiling - resumeUnder { walking = false; overSince = nil }
        } else if atFloor && hr > ceiling + walkOver {
            if let s = overSince { if time - s >= walkAfter { walking = true } } else { overSince = time }
        } else {
            overSince = nil
        }
        return speed
    }
}
