import Foundation
import HealthKit
import CoreLocation

/// Dumps recent workouts from every source (Apple's Workout app, Stride, others) to JSON in the
/// app's Documents folder, so a run can be checked field by field afterwards.
/// `-export` launch argument (pulled with devicectl), or the button in Settings.
enum Export {
    static var requested: Bool { CommandLine.arguments.contains("-export") }

    /// Every type a workout can carry that we want to see in the dump.
    static let quantityTypes: [HKQuantityTypeIdentifier] = [
        .heartRate, .activeEnergyBurned, .basalEnergyBurned, .distanceWalkingRunning, .stepCount,
        .runningPower, .runningSpeed, .runningStrideLength, .runningVerticalOscillation,
        .runningGroundContactTime, .vo2Max, .heartRateRecoveryOneMinute, .flightsClimbed,
        .physicalEffort, .workoutEffortScore, .estimatedWorkoutEffortScore,
    ]

    static var readTypes: Set<HKObjectType> {
        var s: Set<HKObjectType> = [.workoutType(), HKSeriesType.workoutRoute()]
        for id in quantityTypes { s.insert(HKQuantityType(id)) }
        return s
    }

    static func unit(for id: HKQuantityTypeIdentifier) -> HKUnit {
        switch id {
        case .heartRate: return .count().unitDivided(by: .minute())
        case .activeEnergyBurned, .basalEnergyBurned: return .kilocalorie()
        case .distanceWalkingRunning, .runningStrideLength: return .meter()
        case .runningVerticalOscillation: return .meterUnit(with: .centi)
        case .runningGroundContactTime: return .secondUnit(with: .milli)
        case .runningSpeed: return .meter().unitDivided(by: .second())
        case .runningPower: return .watt()
        case .vo2Max: return HKUnit(from: "ml/kg*min")
        case .physicalEffort: return .kilocalorie().unitDivided(by: HKUnit.hour().unitMultiplied(by: .gramUnit(with: .kilo)))
        case .workoutEffortScore, .estimatedWorkoutEffortScore: return .appleEffortScore()
        default: return .count()
        }
    }

    static var directory: URL {
        let d = URL.documentsDirectory.appending(path: "diagnostics", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func iso(_ d: Date) -> String { d.ISO8601Format(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)) }

    static func plain(_ v: Any) -> Any {
        switch v {
        case let q as HKQuantity: return q.description
        case let d as Date: return iso(d)
        case let s as String: return s
        case let n as NSNumber: return n
        default: return String(describing: v)
        }
    }

    /// Writes the dump and returns its URL.
    @discardableResult
    static func run(days: Int = 3) async -> URL? {
        let store = HKHealthStore()
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        try? await store.requestAuthorization(toShare: [], read: readTypes)
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let desc = HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForSamples(withStart: since, end: nil))],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)], limit: 30)
        let workouts = (try? await desc.result(for: store)) ?? []
        var out: [[String: Any]] = []
        for w in workouts { out.append(await dump(w, store: store)) }
        var auth: [String: String] = [:]
        for id in quantityTypes {
            // share status only (iOS never reveals read status); "notDetermined" means never asked
            auth[id.rawValue] = "\(store.authorizationStatus(for: HKQuantityType(id)).rawValue)"
        }
        let root: [String: Any] = [
            "exported": iso(Date()), "days": days, "workouts": out,
            "shareAuthorization (0 notDetermined, 1 denied, 2 authorized)": auth,
            "runLogs": RunLog.list().map(\.lastPathComponent),
        ]
        let url = directory.appending(path: "export-\(Int(Date().timeIntervalSince1970)).json")
        do {
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)
            print("EXPORT \(url.path) \(workouts.count) workouts"); fflush(stdout)
            return url
        } catch {
            print("EXPORT failed: \(error)"); fflush(stdout)
            return nil
        }
    }

    private static func dump(_ w: HKWorkout, store: HKHealthStore) async -> [String: Any] {
        var d: [String: Any] = [
            "uuid": w.uuid.uuidString,
            "activityType": w.workoutActivityType.rawValue,
            "start": iso(w.startDate), "end": iso(w.endDate), "duration": w.duration,
            "source": w.sourceRevision.source.name,
            "bundle": w.sourceRevision.source.bundleIdentifier,
            "sourceVersion": w.sourceRevision.version ?? "",
            "os": { let v = w.sourceRevision.operatingSystemVersion; return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" }(),
            "device": [w.device?.name, w.device?.model, w.device?.hardwareVersion, w.device?.softwareVersion]
                .map { $0 ?? "" },
            "metadata": (w.metadata ?? [:]).mapValues(plain),
        ]
        var stats: [String: Any] = [:]
        for (type, s) in w.allStatistics {
            let id = HKQuantityTypeIdentifier(rawValue: type.identifier)
            let u = unit(for: id)
            var e: [String: Any] = [:]
            if let v = s.sumQuantity()?.doubleValue(for: u) { e["sum"] = v }
            if let v = s.averageQuantity()?.doubleValue(for: u) { e["avg"] = v }
            if let v = s.minimumQuantity()?.doubleValue(for: u) { e["min"] = v }
            if let v = s.maximumQuantity()?.doubleValue(for: u) { e["max"] = v }
            e["unit"] = u.unitString
            stats[type.identifier] = e
        }
        d["statistics"] = stats
        d["events"] = (w.workoutEvents ?? []).map { ev -> [String: Any] in
            ["type": ev.type.rawValue, "start": iso(ev.dateInterval.start), "end": iso(ev.dateInterval.end),
             "metadata": (ev.metadata ?? [:]).mapValues(plain)]
        }
        d["activities"] = w.workoutActivities.map { a -> [String: Any] in
            ["type": a.workoutConfiguration.activityType.rawValue,
             "location": a.workoutConfiguration.locationType.rawValue,
             "start": iso(a.startDate), "end": a.endDate.map(iso) ?? "",
             "events": a.workoutEvents.count, "metadata": (a.metadata ?? [:]).mapValues(plain)]
        }
        // every sample of the interesting types inside the workout, with its source
        let inside = HKQuery.predicateForSamples(withStart: w.startDate, end: w.endDate, options: [])
        var samples: [String: Any] = [:]
        for id in quantityTypes {
            let q = HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(id), predicate: inside)],
                                            sortDescriptors: [SortDescriptor(\.startDate)], limit: 20_000)
            let r = (try? await q.result(for: store)) ?? []
            guard !r.isEmpty else { continue }
            let u = unit(for: id)
            var bySource: [String: Int] = [:]
            for s in r { bySource[s.sourceRevision.source.name, default: 0] += 1 }
            samples[id.rawValue] = [
                "count": r.count, "bySource": bySource, "unit": u.unitString,
                // [seconds since workout start, duration, value, source]
                "values": r.prefix(4000).map { [$0.startDate.timeIntervalSince(w.startDate).rounded(),
                                                $0.endDate.timeIntervalSince($0.startDate),
                                                $0.quantity.doubleValue(for: u),
                                                $0.sourceRevision.source.name] as [Any] },
            ]
        }
        d["samples"] = samples
        d["routes"] = await routes(for: w, store: store)
        return d
    }

    private static func routes(for w: HKWorkout, store: HKHealthStore) async -> [[String: Any]] {
        let q = HKSampleQueryDescriptor(predicates: [.sample(type: HKSeriesType.workoutRoute(),
                                                             predicate: HKQuery.predicateForObjects(from: w))],
                                        sortDescriptors: [])
        let rs = (try? await q.result(for: store)) ?? []
        var out: [[String: Any]] = []
        for case let r as HKWorkoutRoute in rs {
            var pts: [CLLocation] = []
            let d = HKWorkoutRouteQueryDescriptor(r)
            do { for try await l in d.results(for: store) { pts.append(l) } } catch {}
            out.append([
                "count": r.count, "read": pts.count, "source": r.sourceRevision.source.name,
                "metadata": (r.metadata ?? [:]).mapValues(plain),
                // [s since start, lat, lon, alt, hAcc, vAcc, speed, course]
                "points": pts.map { [$0.timestamp.timeIntervalSince(w.startDate), $0.coordinate.latitude,
                                     $0.coordinate.longitude, $0.altitude, $0.horizontalAccuracy,
                                     $0.verticalAccuracy, $0.speed, $0.course] },
            ])
        }
        return out
    }
}
