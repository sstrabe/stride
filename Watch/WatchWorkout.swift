import Foundation
import HealthKit
import Observation

/// The Watch side: runs the HealthKit workout (rings, heart rate, Fitness) and mirrors it to the
/// iPhone, which measures the stride and plays the click. Shows what the iPhone reports.
@MainActor
@Observable
final class WatchWorkout: NSObject {
    static let shared = WatchWorkout()

    private let store = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?

    private(set) var running = false
    private(set) var startDate: Date?
    private(set) var status: RunStatus?
    private(set) var heartRate: Double?
    private(set) var phoneConnected = false
    private(set) var message: String?
    private(set) var saved: String?

    func requestAuthorization() async {
        let share: Set<HKSampleType> = [.workoutType(), HKQuantityType(.distanceWalkingRunning),
                                        HKQuantityType(.activeEnergyBurned), HKQuantityType(.heartRate)]
        let read: Set<HKObjectType> = [.workoutType(), HKQuantityType(.heartRate),
                                       HKQuantityType(.distanceWalkingRunning), HKQuantityType(.activeEnergyBurned)]
        try? await store.requestAuthorization(toShare: share, read: read)
    }

    nonisolated static var defaultConfiguration: HKWorkoutConfiguration {
        let c = HKWorkoutConfiguration()
        c.activityType = .running
        c.locationType = .outdoor
        return c
    }

    func start(_ config: HKWorkoutConfiguration = defaultConfiguration) async {
        guard !running else { return }
        message = nil; saved = nil
        do {
            let s = try HKWorkoutSession(healthStore: store, configuration: config)
            let b = s.associatedWorkoutBuilder()
            b.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            s.delegate = self
            b.delegate = self
            session = s; builder = b
            let now = Date()
            s.startActivity(with: now)
            try await b.beginCollection(at: now)
            startDate = now
            running = true
            do {
                try await s.startMirroringToCompanionDevice()
                phoneConnected = true
            } catch {
                message = "iPhone not reached: no click"
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func end() { session?.end() }

    func setTarget(_ seconds: Double) { send(.setTarget(seconds)) }
    func setHold(_ hold: Bool) { send(.setHold(hold)) }

    private func send(_ m: RemoteMessage) {
        guard let s = session, let d = m.encoded() else { return }
        Task { try? await s.sendToRemoteWorkoutSession(data: d) }
    }

    private func finish(at date: Date) async {
        guard let b = builder else { return }
        do {
            try await b.endCollection(at: date)
            if let st = status {
                try? await b.addMetadata(["StrideTargetPace": "\(Pace.format(st.targetSecondsPerUnit)) \(st.unit.paceSuffix)"])
            }
            _ = try await b.finishWorkout()
            saved = "Saved to Fitness"
        } catch {
            saved = "Not saved: \(error.localizedDescription)"
        }
        session = nil; builder = nil
        running = false; phoneConnected = false
    }
}

extension WatchWorkout: HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutSession(_ s: HKWorkoutSession, didChangeTo to: HKWorkoutSessionState,
                                    from: HKWorkoutSessionState, date: Date) {
        guard to == .ended else { return }
        Task { @MainActor in await self.finish(at: date) }
    }

    nonisolated func workoutSession(_ s: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in self.message = error.localizedDescription }
    }

    nonisolated func workoutSession(_ s: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        let msgs = data.compactMap(RemoteMessage.decode)
        Task { @MainActor in
            self.phoneConnected = true
            for m in msgs { if case .status(let st) = m { self.status = st } }
        }
    }

    nonisolated func workoutSession(_ s: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?) {
        Task { @MainActor in self.phoneConnected = false }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ b: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ b: HKLiveWorkoutBuilder, didCollectDataOf types: Set<HKSampleType>) {
        let hr = HKQuantityType(.heartRate)
        guard types.contains(hr),
              let v = b.statistics(for: hr)?.mostRecentQuantity()?.doubleValue(for: .count().unitDivided(by: .minute()))
        else { return }
        Task { @MainActor in self.heartRate = v }
    }
}
