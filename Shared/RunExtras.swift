import Foundation
import HealthKit

/// What a Stride run writes to Health. The iPhone and the Watch ask for the same list, so
/// whichever prompt the user answers covers both.
enum RunTypes {
    static let share: Set<HKSampleType> = [
        .workoutType(), HKSeriesType.workoutRoute(),
        HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned), HKQuantityType(.basalEnergyBurned),
        HKQuantityType(.distanceWalkingRunning), HKQuantityType(.stepCount),
        HKQuantityType(.runningPower), HKQuantityType(.runningSpeed), HKQuantityType(.runningStrideLength),
        HKQuantityType(.runningVerticalOscillation), HKQuantityType(.runningGroundContactTime),
    ]

    static func configuration(outdoor: Bool) -> HKWorkoutConfiguration {
        let c = HKWorkoutConfiguration()
        c.activityType = .running
        c.locationType = outdoor ? .outdoor : .indoor
        return c
    }
}

/// Split boundaries like Apple's Workout app writes them: a segment per kilometre and one per
/// mile (two overlapping series), each closed when the distance passes the mark, the last one
/// at the end of the workout.
struct SplitTracker: Sendable {
    struct Split: Equatable, Sendable { var start: Date; var end: Date; var unitMeters: Double; var index: Int; var partial: Bool }

    static let units: [Double] = [1000, 1609.344]

    private var lastDate: Date
    private var lastDistance: Double = 0
    private var splitStart: [Double: Date] = [:]
    private var count: [Double: Int] = [:]

    init(start: Date) {
        lastDate = start
        for u in Self.units { splitStart[u] = start; count[u] = 0 }
    }

    /// Feeds the run's total distance at `date`; returns the splits it completed, with the
    /// crossing time interpolated between the previous and this reading.
    mutating func add(distance: Double, at date: Date) -> [Split] {
        guard distance > lastDistance, date >= lastDate else { lastDate = max(lastDate, date); return [] }
        var out: [Split] = []
        for u in Self.units {
            while Double(count[u]! + 1) * u <= distance {
                let mark = Double(count[u]! + 1) * u
                let f = (mark - lastDistance) / (distance - lastDistance)
                let t = lastDate.addingTimeInterval(date.timeIntervalSince(lastDate) * f)
                count[u]! += 1
                out.append(Split(start: splitStart[u]!, end: t, unitMeters: u, index: count[u]!, partial: false))
                splitStart[u] = t
            }
        }
        lastDistance = distance; lastDate = date
        return out
    }

    /// The open split of each unit, ended at `date` (skipped when it is under a few seconds).
    func finish(at date: Date) -> [Split] {
        Self.units.compactMap { u in
            guard let s = splitStart[u], date.timeIntervalSince(s) >= 5 else { return nil }
            return Split(start: s, end: date, unitMeters: u, index: count[u]! + 1, partial: true)
        }
    }
}

/// Elevation gain and loss from GPS altitudes, counting a climb only once it exceeds a few
/// metres from the last turning point, so GPS noise on the flat doesn't add up.
struct ElevationTracker: Sendable {
    var threshold: Double = 3
    private(set) var ascended: Double = 0
    private(set) var descended: Double = 0
    private var ref: Double?
    private var smoothed: Double?

    mutating func add(altitude: Double, verticalAccuracy: Double) {
        guard verticalAccuracy > 0, verticalAccuracy <= 20 else { return }
        let s = smoothed.map { $0 + 0.3 * (altitude - $0) } ?? altitude
        smoothed = s
        guard let r = ref else { ref = s; return }
        if s - r >= threshold { ascended += s - r; ref = s }
        else if r - s >= threshold { descended += r - s; ref = s }
    }
}
