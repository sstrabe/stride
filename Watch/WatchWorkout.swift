import Foundation
import HealthKit
import CoreLocation
import Observation

/// The Watch side: runs the HealthKit workout and mirrors it to the iPhone, which measures the
/// stride and plays the click. Saves what Apple's Workout app saves for a run: heart rate,
/// energy, distance, running form (power, stride length, ground contact time, vertical
/// oscillation, speed, collected by the live data source once authorized), the GPS route with
/// altitude, elevation gain, km and mile splits as segment events, and the time zone.
@MainActor
@Observable
final class WatchWorkout: NSObject {
    static let shared = WatchWorkout()

    private let store = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private var routeBuilder: HKWorkoutRouteBuilder?
    @ObservationIgnored private let location = CLLocationManager()
    @ObservationIgnored private var routeBuffer: [CLLocation] = []
    @ObservationIgnored private var routePoints = 0
    @ObservationIgnored private var routeRejected = 0
    @ObservationIgnored private var splits = SplitTracker(start: Date())
    @ObservationIgnored private var splitCount = 0
    @ObservationIgnored private var elevation = ElevationTracker()
    @ObservationIgnored private var lastDiag = Date.distantPast
    @ObservationIgnored private var outdoor = true
    @ObservationIgnored private var diagLines: [String] = []

    private(set) var running = false
    private(set) var startDate: Date?
    private(set) var status: RunStatus?
    private(set) var heartRate: Double?
    private(set) var phoneConnected = false
    private(set) var message: String?
    private(set) var saved: String?

    static var shareTypes: Set<HKSampleType> { RunTypes.share }

    override init() {
        super.init()
        location.delegate = self
        location.activityType = .fitness
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = kCLDistanceFilterNone
    }

    func requestAuthorization() async {
        let read: Set<HKObjectType> = Set(Self.shareTypes.map { $0 as HKObjectType })
        try? await store.requestAuthorization(toShare: Self.shareTypes, read: read)
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
    }

    func start(_ config: HKWorkoutConfiguration = RunTypes.configuration(outdoor: true)) async {
        guard !running else { return }
        message = nil; saved = nil
        diagLines = []
        outdoor = config.locationType != .indoor
        // started from the iPhone, the run view's request may not have happened yet
        if outdoor, location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        do {
            let s = try HKWorkoutSession(healthStore: store, configuration: config)
            let b = s.associatedWorkoutBuilder()
            let src = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            b.dataSource = src
            s.delegate = self
            b.delegate = self
            session = s; builder = b
            let now = Date()
            splits = SplitTracker(start: now); splitCount = 0
            elevation = ElevationTracker()
            routeBuffer = []; routePoints = 0; routeRejected = 0
            s.startActivity(with: now)
            try await b.beginCollection(at: now)
            startDate = now
            running = true
            if outdoor {
                routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
                location.allowsBackgroundLocationUpdates = true
                location.startUpdatingLocation()
            }
            do {
                try await s.startMirroringToCompanionDevice()
                phoneConnected = true
            } catch {
                message = "iPhone not reached: no click"
            }
            // the previous run's report (its session had ended before it could be sent)
            if let last = UserDefaults.standard.string(forKey: "lastFinish") { diag("previous run: \(last)") }
            let auth = Self.shareTypes.compactMap { t -> String? in
                let st = store.authorizationStatus(for: t)
                return st == .sharingAuthorized ? nil : "\(Self.short(t)):\(st.rawValue)"
            }
            diag("start \(outdoor ? "outdoor" : "indoor"); not authorized: \(auth.isEmpty ? "none" : auth.joined(separator: ","))")
            diag("collecting: \(src.typesToCollect.map(Self.short).sorted().joined(separator: ","))")
            diag("location auth \(location.authorizationStatus.rawValue), accuracy \(location.accuracyAuthorization.rawValue)")
        } catch {
            message = error.localizedDescription
        }
    }

    nonisolated private static func short(_ t: HKObjectType) -> String {
        t.identifier.replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
    }

    func end() { session?.end() }

    func setTarget(_ seconds: Double) { send(.setTarget(seconds)) }
    func setHold(_ hold: Bool) { send(.setHold(hold)) }

    private func send(_ m: RemoteMessage) {
        guard let s = session, let d = m.encoded() else { return }
        Task { try? await s.sendToRemoteWorkoutSession(data: d) }
    }

    /// A line for the iPhone's run log (and the workout's metadata).
    private func diag(_ s: String) {
        diagLines.append("\(Int(Date().timeIntervalSince(startDate ?? Date()))) \(s)")
        send(.diag(s))
    }

    // MARK: route + elevation

    fileprivate func locations(_ locs: [CLLocation]) {
        guard running, outdoor else { return }
        for l in locs {
            guard l.horizontalAccuracy >= 0, l.horizontalAccuracy <= 50 else { routeRejected += 1; continue }
            routeBuffer.append(l)
            elevation.add(altitude: l.altitude, verticalAccuracy: l.verticalAccuracy)
        }
        if routeBuffer.count >= 20 { flushRoute() }
        if Date().timeIntervalSince(lastDiag) >= 60 {
            lastDiag = Date()
            diag("route \(routePoints + routeBuffer.count) pts (\(routeRejected) rejected), up \(Int(elevation.ascended)) m, splits \(splitCount)")
        }
    }

    private func flushRoute() {
        guard let rb = routeBuilder, !routeBuffer.isEmpty else { return }
        let batch = routeBuffer
        routeBuffer.removeAll()
        routePoints += batch.count
        Task {
            do { try await rb.insertRouteData(batch) }
            catch { self.diag("route insert failed: \(error.localizedDescription)") }
        }
    }

    // MARK: splits

    fileprivate func distanceUpdate(_ meters: Double, at date: Date) {
        let done = splits.add(distance: meters, at: date)
        guard !done.isEmpty, let b = builder else { return }
        splitCount += done.count
        for s in done { diag("split \(s.unitMeters == 1000 ? "km" : "mi") \(s.index): \(Int(s.end.timeIntervalSince(s.start))) s") }
        Task { try? await b.addWorkoutEvents(done.map(Self.event)) }
    }

    nonisolated private static func event(_ s: SplitTracker.Split) -> HKWorkoutEvent {
        HKWorkoutEvent(type: .segment, dateInterval: DateInterval(start: s.start, end: max(s.end, s.start)), metadata: nil)
    }

    // MARK: finish

    private func finish(at date: Date) async {
        guard let b = builder else { return }
        location.stopUpdatingLocation()
        location.allowsBackgroundLocationUpdates = false
        flushRoute()
        var report: [String] = []
        do {
            try await b.addWorkoutEvents(splits.finish(at: date).map(Self.event))
            try await b.endCollection(at: date)
            var meta: [String: Any] = [
                HKMetadataKeyIndoorWorkout: !outdoor,
                HKMetadataKeyTimeZone: TimeZone.current.identifier,
            ]
            if outdoor {
                meta[HKMetadataKeyElevationAscended] = HKQuantity(unit: .meter(), doubleValue: elevation.ascended)
                meta[HKMetadataKeyElevationDescended] = HKQuantity(unit: .meter(), doubleValue: elevation.descended)
            }
            if let st = status { meta["StrideTargetPace"] = "\(Pace.format(st.targetSecondsPerUnit)) \(st.unit.paceSuffix)" }
            meta["StrideDiag"] = diagLines.suffix(30).joined(separator: "\n")
            try? await b.addMetadata(meta)
            report.append("route \(routePoints) pts, up \(Int(elevation.ascended)) m, \(splitCount) splits")
            guard let workout = try await b.finishWorkout() else { throw CocoaError(.coderValueNotFound) }
            if let rb = routeBuilder {
                if routePoints > 0 {
                    do { _ = try await rb.finishRoute(with: workout, metadata: nil); report.append("route saved") }
                    catch { report.append("route failed: \(error.localizedDescription)") }
                } else { rb.discard(); report.append("no route points") }
            }
            saved = "Saved to Fitness"
        } catch {
            saved = "Not saved: \(error.localizedDescription)"
        }
        report.append(saved ?? "")
        let line = "\(ISO8601DateFormatter().string(from: date)) " + report.joined(separator: "; ")
        UserDefaults.standard.set(line, forKey: "lastFinish")
        session = nil; builder = nil; routeBuilder = nil
        running = false; phoneConnected = false
    }
}

extension WatchWorkout: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.locations(locations) }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.diag("location error: \(error.localizedDescription)") }
    }
}

extension WatchWorkout: HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutSession(_ s: HKWorkoutSession, didChangeTo to: HKWorkoutSessionState,
                                    from: HKWorkoutSessionState, date: Date) {
        guard to == .ended else { return }
        Task { @MainActor in await self.finish(at: date) }
    }

    nonisolated func workoutSession(_ s: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in self.message = error.localizedDescription; self.diag("session error: \(error.localizedDescription)") }
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
        let hr = HKQuantityType(.heartRate), dist = HKQuantityType(.distanceWalkingRunning), steps = HKQuantityType(.stepCount)
        let v = types.contains(hr) ? b.statistics(for: hr)?.mostRecentQuantity()?.doubleValue(for: .count().unitDivided(by: .minute())) : nil
        let ds = types.contains(dist) ? b.statistics(for: dist) : nil
        let d = ds?.sumQuantity()?.doubleValue(for: .meter())
        let at = ds?.mostRecentQuantityDateInterval()?.end ?? Date()
        let changed = types.contains(dist) || types.contains(steps)
        let totD = b.statistics(for: dist)?.sumQuantity()?.doubleValue(for: .meter())
        let totS = b.statistics(for: steps)?.sumQuantity()?.doubleValue(for: .count())
        Task { @MainActor in
            if let v { self.heartRate = v; self.send(.heartRate(v)) }
            if let d { self.distanceUpdate(d, at: at) }
            // the Watch's distance (GPS + motion, calibrated) is better than the iPhone's GPS
            // alone; with its own steps the iPhone gets a consistent step length from it
            if changed, let totD, let totS { self.send(.totals(distance: totD, steps: totS)) }
        }
    }
}
