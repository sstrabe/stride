import Foundation
import HealthKit
import CoreLocation

/// The run's HealthKit side on the iPhone: either its own workout session (iOS 26 workouts on
/// iPhone, which land in Fitness), or the mirror of a session that the Watch runs (rings, heart
/// rate; the Watch saves the workout then).
@MainActor
final class Health: NSObject {
    let store = HKHealthStore()
    private(set) var session: HKWorkoutSession?
    private(set) var builder: HKLiveWorkoutBuilder?
    private var routeBuilder: HKWorkoutRouteBuilder?
    private(set) var isMirrored = false

    var onMessage: ((RemoteMessage) -> Void)?
    var onMirrorStarted: (() -> Void)?
    var onMirrorEnded: (() -> Void)?
    var onHeartRate: ((Double) -> Void)?

    static var available: Bool { HKHealthStore.isHealthDataAvailable() }

    static let configuration: HKWorkoutConfiguration = {
        let c = HKWorkoutConfiguration()
        c.activityType = .running
        c.locationType = .outdoor
        return c
    }()

    override init() {
        super.init()
        // Must be set early: the system launches us in the background when the Watch mirrors.
        store.workoutSessionMirroringStartHandler = { [weak self] mirrored in
            Task { @MainActor in self?.attachMirrored(mirrored) }
        }
    }

    func requestAuthorization() async {
        guard Self.available else { return }
        let share: Set<HKSampleType> = [
            .workoutType(), HKSeriesType.workoutRoute(),
            HKQuantityType(.distanceWalkingRunning), HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.runningStrideLength), HKQuantityType(.runningSpeed),
        ]
        let read: Set<HKObjectType> = [
            .workoutType(), HKQuantityType(.heartRate), HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.runningStrideLength), HKQuantityType(.runningSpeed),
        ]
        try? await store.requestAuthorization(toShare: share, read: read)
    }

    // MARK: past runs

    /// Running stride length and speed samples from the last `days` days (Apple Watch writes both
    /// during runs), as (sample midpoint, value).
    func recentStrideAndSpeed(days: Int = 90) async -> (strides: [(Date, Double)], speeds: [(Date, Double)]) {
        guard Self.available else { return ([], []) }
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let pred = HKQuery.predicateForSamples(withStart: since, end: nil)
        func fetch(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit) async -> [(Date, Double)] {
            let d = HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(id), predicate: pred)],
                                            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)], limit: 20_000)
            let r = (try? await d.result(for: store)) ?? []
            return r.map { ($0.startDate.addingTimeInterval($0.endDate.timeIntervalSince($0.startDate) / 2),
                            $0.quantity.doubleValue(for: unit)) }
        }
        async let st = fetch(.runningStrideLength, .meter())
        async let sp = fetch(.runningSpeed, HKUnit.meter().unitDivided(by: .second()))
        return await (st, sp)
    }

    // MARK: Watch

    /// Asks the Watch to start the run; it mirrors its session back here (attachMirrored).
    func startOnWatch() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            store.startWatchApp(with: Self.configuration) { ok, error in
                if ok { c.resume() } else { c.resume(throwing: error ?? CocoaError(.featureUnsupported)) }
            }
        }
    }

    private func attachMirrored(_ s: HKWorkoutSession) {
        // already recording on the iPhone: keep that workout, don't take over the Watch's
        guard session == nil || isMirrored else { return }
        session = s
        isMirrored = true
        s.delegate = self
        let b = s.associatedWorkoutBuilder()
        b.delegate = self
        builder = b
        onMirrorStarted?()
    }

    func send(_ m: RemoteMessage) {
        guard isMirrored, let s = session, let d = m.encoded() else { return }
        Task { try? await s.sendToRemoteWorkoutSession(data: d) }
    }

    // MARK: Phone

    func startOnPhone(at date: Date) async throws {
        let s = try HKWorkoutSession(healthStore: store, configuration: Self.configuration)
        let b = s.associatedWorkoutBuilder()
        b.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: Self.configuration)
        s.delegate = self
        b.delegate = self
        session = s; builder = b; isMirrored = false
        routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: nil)
        s.startActivity(with: date)
        try await b.beginCollection(at: date)
    }

    func addRoute(_ locations: [CLLocation]) {
        guard !isMirrored, let rb = routeBuilder, !locations.isEmpty else { return }
        Task { try? await rb.insertRouteData(locations) }
    }

    struct Summary { var distance: Double; var strides: [(Date, Double)]; var speeds: [(Date, Double)]; var targetSecondsPerUnit: Double; var unit: DistanceUnit }

    /// Ends the run. Returns a line for the UI.
    func finish(at end: Date, summary: Summary) async -> String {
        guard let s = session, let b = builder else { return "Not recorded in Health" }
        defer { session = nil; builder = nil; routeBuilder = nil; isMirrored = false }
        if isMirrored {
            s.stopActivity(with: end)
            s.end()
            return "Saved by Apple Watch to Fitness"
        }
        s.stopActivity(with: end)
        s.end()
        do {
            try await b.endCollection(at: end)
            let start = b.startDate ?? end
            var samples: [HKSample] = []
            let distType = HKQuantityType(.distanceWalkingRunning)
            if b.statistics(for: distType)?.sumQuantity() == nil, summary.distance > 1 {
                samples.append(HKQuantitySample(type: distType,
                                                quantity: HKQuantity(unit: .meter(), doubleValue: summary.distance),
                                                start: start, end: end))
            }
            let strideType = HKQuantityType(.runningStrideLength)
            for (date, length) in summary.strides where date > start && date <= end {
                let q = HKQuantity(unit: .meter(), doubleValue: length)
                samples.append(HKQuantitySample(type: strideType, quantity: q, start: date.addingTimeInterval(-60), end: date))
            }
            let speedType = HKQuantityType(.runningSpeed)
            for (date, v) in summary.speeds where date > start && date <= end && v > 0 {
                let q = HKQuantity(unit: HKUnit.meter().unitDivided(by: .second()), doubleValue: v)
                samples.append(HKQuantitySample(type: speedType, quantity: q, start: date.addingTimeInterval(-60), end: date))
            }
            if !samples.isEmpty { try await b.addSamples(samples) }
            try await b.addMetadata([
                HKMetadataKeyIndoorWorkout: false,
                "StrideTargetPace": "\(Pace.format(summary.targetSecondsPerUnit)) \(summary.unit.paceSuffix)",
            ])
            guard let workout = try await b.finishWorkout() else { return "Workout not saved" }
            if let rb = routeBuilder { _ = try? await rb.finishRoute(with: workout, metadata: nil) }
            return "Saved to Health and Fitness"
        } catch {
            return "Health: \(error.localizedDescription)"
        }
    }

    /// Throws the run away (nothing saved).
    func discard() {
        session?.end()
        builder?.discardWorkout()
        routeBuilder?.discard()
        session = nil; builder = nil; routeBuilder = nil; isMirrored = false
    }
}

extension Health: HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutSession(_ s: HKWorkoutSession, didChangeTo to: HKWorkoutSessionState,
                                    from: HKWorkoutSessionState, date: Date) {
        guard to == .ended || to == .stopped else { return }
        Task { @MainActor in
            if self.isMirrored, self.session === s, to == .ended { self.onMirrorEnded?() }
        }
    }

    nonisolated func workoutSession(_ s: HKWorkoutSession, didFailWithError error: Error) {}

    nonisolated func workoutSession(_ s: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        let msgs = data.compactMap(RemoteMessage.decode)
        Task { @MainActor in msgs.forEach { self.onMessage?($0) } }
    }

    nonisolated func workoutSession(_ s: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?) {
        Task { @MainActor in
            if self.isMirrored, self.session === s { self.onMirrorEnded?() }
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ b: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ b: HKLiveWorkoutBuilder, didCollectDataOf types: Set<HKSampleType>) {
        let hr = HKQuantityType(.heartRate)
        guard types.contains(hr),
              let v = b.statistics(for: hr)?.mostRecentQuantity()?.doubleValue(for: .count().unitDivided(by: .minute()))
        else { return }
        Task { @MainActor in self.onHeartRate?(v) }
    }
}
