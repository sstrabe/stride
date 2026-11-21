import Foundation
import AVFoundation
import CoreLocation
import CoreMotion
import Observation

/// One run: GPS + pedometer -> step length -> click tempo; plus the Health workout and the Watch.
@MainActor
@Observable
final class RunModel: NSObject {
    enum State: Equatable { case idle, starting, running, finishing }
    /// What the click follows: the target pace, or a heart-rate ceiling (easy runs).
    enum PaceBy: String, CaseIterable { case pace, heartRate }
    /// Who records the run in Health.
    enum Recording: String, CaseIterable { case phone, watch, workoutApp }

    // MARK: settings (kept in UserDefaults)
    var targetSeconds: Double = 502 { didSet { saveSettings(); targetChanged() } }
    var unit: DistanceUnit = .mile { didSet { if oldValue != unit && !loading { convertTarget(from: oldValue) }; saveSettings() } }
    var minCadence: Double = 140 { didSet { saveSettings(); rangeChanged() } }
    var maxCadence: Double = 200 { didSet { saveSettings(); rangeChanged() } }
    var startCadence: Double = 170 { didSet { saveSettings(); targetChanged() } }
    var volume: Double = 1 { didSet { metronome.volume = walking ? 0 : Float(volume); saveSettings() } }
    var lowerMusic: Bool = true { didSet { metronome.duckOthers = lowerMusic; saveSettings() } }
    var recording: Recording = .phone { didSet { saveSettings() } }
    var outdoor: Bool = true { didSet { saveSettings() } }
    /// Goal distance in metres (0: none). The click then aims for the whole distance at the
    /// target pace, making up time when behind (GoalPace).
    var goalMeters: Double = 0 { didSet { saveSettings() } }
    var goal: Double? { paceBy == .pace && goalMeters > 0 ? goalMeters : nil }
    var paceBy: PaceBy = .pace { didSet { saveSettings() } }
    /// Heart-rate mode: keep the heart rate under this (bpm). The target pace is the start.
    var hrCeiling: Double = 150 { didSet { hrGov.ceiling = hrCeiling; saveSettings(); sendStatus(force: true) } }

    // MARK: live
    private(set) var state: State = .idle
    private(set) var clickCadence: Double = 170
    private(set) var wantedCadence: Double?
    private(set) var stepLength: Double?
    private(set) var measuredCadence: Double?
    private(set) var currentSpeed: Double?
    private(set) var distance: Double = 0
    private(set) var startDate: Date?
    private(set) var heartRate: Double? { didSet { if heartRate != nil { heartRateAt = Date() } } }
    @ObservationIgnored private var heartRateAt: Date?
    private(set) var walking = false
    @ObservationIgnored private var hrGov = HeartRateGovernor(ceiling: 150, startSpeed: 2.7)
    @ObservationIgnored private let speech = AVSpeechSynthesizer()
    private(set) var behind: Double?
    private(set) var aimSpeed: Double?
    @ObservationIgnored private var goalReached = false
    private(set) var gpsGood = false
    private(set) var recordingOn: String = ""
    private(set) var message: String?
    private(set) var previewing = false
    var holding = false { didSet { if holding != oldValue { health.send(.setHold(holding)) } } }

    var targetSpeed: Double { Pace.speed(secondsPer: targetSeconds, unit: unit) }

    /// Your usual step length at the target speed, from past runs in Apple Health.
    private(set) var healthStride: StrideFit.Estimate?
    @ObservationIgnored private var healthPoints: [StrideFit.Point] = []
    @ObservationIgnored private var healthUnpaired: [Double] = []

    /// The tempo a run starts at: the target speed at your usual stride from Health, else the
    /// start tempo from Settings.
    var openingCadence: Double {
        guard let h = healthStride else { return startCadence }
        return min(max(Cadence.required(speed: targetSpeed, stepLength: h.stride), minCadence), maxCadence)
    }
    var currentSecondsPerUnit: Double? { currentSpeed.flatMap { Pace.seconds(speed: $0, unit: unit) } }

    // MARK: machinery
    let health = Health()
    private let metronome = Metronome()
    private let location = CLLocationManager()
    private let pedometer = CMPedometer()
    private var estimator = StepLengthEstimator()
    private var governor = CadenceGovernor(targetSpeed: 3.2, startCadence: 170)
    private var tick: Timer?
    private var lastLocation: CLLocation?
    private var lastGoodFix: Date?
    private var gpsDistance: Double = 0
    private var pedoSteps: Double = 0
    private var pedoDistance: Double = 0
    private var routeBuffer: [CLLocation] = []
    private var strides: [(Date, Double)] = []
    private var speeds: [(Date, Double)] = []
    private var speedBucket: [Double] = []
    private var strideBucket: [Double] = []
    private var lastStrideMinute: Date?
    private var lastStatusSent = Date.distantPast
    private let defaults = UserDefaults.standard
    private let log = RunLog()
    private var splitTracker = SplitTracker(start: Date())
    private var splitList: [SplitTracker.Split] = []
    private var elevation = ElevationTracker()
    private var routePoints = 0
    private var watchDistance: Double?
    private var watchSteps: Double?
    private var lastWatchTotals: Date?
    private var gpsPathDistance: Double = 0
    private var watchFresh: Bool { lastWatchTotals.map { Date().timeIntervalSince($0) < 10 } ?? false }

    override init() {
        super.init()
        loadSettings()
        clickCadence = startCadence
        governor = CadenceGovernor(targetSpeed: targetSpeed, startCadence: startCadence, range: minCadence...maxCadence)
        metronome.volume = Float(volume)
        metronome.duckOthers = lowerMusic
        location.delegate = self
        location.activityType = .fitness
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = kCLDistanceFilterNone
        health.onMessage = { [weak self] m in self?.handle(m) }
        health.onHeartRate = { [weak self] hr in self?.heartRate = hr }
        health.onMirrorStarted = { [weak self] in self?.mirrorStarted() }
        health.onMirrorEnded = { [weak self] in self?.mirrorEnded() }
    }

    func prepare() async {
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        await health.requestAuthorization()
        await loadHealthStride()
    }

    func loadHealthStride() async {
        let (st, sp) = await health.recentStrideAndSpeed()
        let r = StrideFit.pair(strides: st, speeds: sp)
        healthPoints = r.points; healthUnpaired = r.unpaired
        refitStride()
    }

    private func refitStride() {
        healthStride = StrideFit.estimate(at: targetSpeed, points: healthPoints, strides: healthUnpaired)
        if state == .idle && !previewing { clickCadence = openingCadence }
    }

    // MARK: start / stop

    func start() async {
        guard state == .idle else { return }
        state = .starting
        message = nil
        stopPreview()
        resetLive()
        if recording == .workoutApp {
            // Apple's Workout app on the Watch records the run; Stride starts no workout of its
            // own (a second one would end the Watch's or double the run in Fitness) and only clicks.
            recordingOn = "Workout app records the run"
            beginSensors(at: Date())
        } else if recording == .watch && Health.available {
            do {
                try await health.startOnWatch(outdoor: outdoor)
                recordingOn = "Waiting for Apple Watch…"
                // mirrorStarted() takes it from here; fall back if the Watch doesn't answer
                try? await Task.sleep(for: .seconds(12))
                if state == .starting && !health.isMirrored {
                    message = "Apple Watch didn't answer; recording on iPhone."
                    await startLocal()
                }
            } catch {
                message = "Apple Watch: \(error.localizedDescription). Recording on iPhone."
                await startLocal()
            }
        } else {
            await startLocal()
        }
    }

    private func startLocal() async {
        let now = Date()
        if Health.available {
            do {
                try await health.startOnPhone(at: now, outdoor: outdoor)
                recordingOn = "Recording on iPhone"
            } catch {
                recordingOn = "Not recording in Health"
                message = "Health: \(error.localizedDescription)"
            }
        } else {
            recordingOn = "Not recording in Health"
        }
        beginSensors(at: now)
    }

    private func mirrorStarted() {
        // The Watch runs the workout (started from here or on the Watch itself).
        if state == .running && !health.isMirrored { log.event("mirror ignored: recording on iPhone"); return }
        recordingOn = "Recording on Apple Watch"
        if state != .running { resetLive(); beginSensors(at: health.builder?.startDate ?? Date()) }
        log.event("mirror started")
        sendStatus(force: true)
    }

    private func mirrorEnded() {
        log.event("mirror ended")
        guard state == .running else { return }
        Task { await stop() }
    }

    private func beginSensors(at date: Date) {
        startDate = date
        state = .running
        splitTracker = SplitTracker(start: date); splitList = []; elevation = ElevationTracker(); routePoints = 0
        hrGov = HeartRateGovernor(ceiling: hrCeiling, startSpeed: targetSpeed)
        log.begin([
            "recording": recording.rawValue, "outdoor": outdoor, "recordingOn": recordingOn, "mirrored": health.isMirrored,
            "targetSecondsPerUnit": targetSeconds, "unit": unit.rawValue, "targetSpeed": targetSpeed,
            "goalMeters": goalMeters, "paceBy": paceBy.rawValue, "hrCeiling": hrCeiling, "lowerMusic": lowerMusic, "volume": volume, "minCadence": minCadence, "maxCadence": maxCadence, "startCadence": startCadence,
            "openingCadence": openingCadence, "healthStride": healthStride.map { [$0.stride, $0.bySpeed] as [Any] as Any } ?? NSNull(),
            "healthPoints": healthPoints.count, "workoutStart": Export.iso(date),
            "app": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "pedometer": CMPedometer.isStepCountingAvailable(), "locationAuth": location.authorizationStatus.rawValue,
        ])
        if let message { log.event("message: \(message)") }
        location.allowsBackgroundLocationUpdates = true
        location.showsBackgroundLocationIndicator = true
        // indoors GPS only adds noise: distance comes from the step counter then
        if outdoor { location.startUpdatingLocation() }
        if CMPedometer.isStepCountingAvailable() {
            pedometer.startUpdates(from: date) { [weak self] data, _ in
                guard let data else { return }
                let steps = data.numberOfSteps.doubleValue
                let dist = data.distance?.doubleValue
                Task { @MainActor in self?.pedometerUpdate(steps: steps, distance: dist) }
            }
        }
        governor = CadenceGovernor(targetSpeed: targetSpeed, startCadence: openingCadence, range: minCadence...maxCadence)
        clickCadence = governor.cadence
        metronome.bpm = clickCadence
        do { try metronome.start() } catch { message = "Audio: \(error.localizedDescription)"; log.event("audio failed: \(error)") }
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
    }

    func stop(discard: Bool = false) async {
        guard state == .running || state == .starting else { return }
        state = .finishing
        let end = Date()
        tick?.invalidate(); tick = nil
        metronome.stop()
        location.stopUpdatingLocation()
        location.allowsBackgroundLocationUpdates = false
        pedometer.stopUpdates()
        flushRoute()
        flushStride(force: true)
        if discard {
            health.discard()
            recordingOn = "Discarded"
        } else if recording == .workoutApp && health.session == nil {
            recordingOn = "Click only: end the run in the Workout app"
        } else {
            recordingOn = await health.finish(at: end, summary: .init(
                distance: distance, strides: strides, speeds: speeds, targetSecondsPerUnit: targetSeconds, unit: unit,
                goalMeters: goalMeters,
                outdoor: outdoor, splits: splitList + splitTracker.finish(at: end),
                ascended: elevation.ascended, descended: elevation.descended, routePoints: routePoints))
        }
        log.end(["result": recordingOn, "discarded": discard, "distance": distance, "routePoints": routePoints,
                 "ascended": elevation.ascended, "descended": elevation.descended, "splits": splitList.count,
                 "strideSamples": strides.count, "speedSamples": speeds.count])
        state = .idle
    }

    // MARK: preview (click at the start tempo without a run)

    func togglePreview() {
        if previewing { stopPreview(); return }
        guard state == .idle else { return }
        metronome.bpm = openingCadence
        do { try metronome.start(); previewing = true } catch { message = "Audio: \(error.localizedDescription)" }
    }

    private func stopPreview() {
        guard previewing else { return }
        metronome.stop(); previewing = false
    }

    // MARK: sensor input

    private func pedometerUpdate(steps: Double, distance pd: Double?) {
        pedoSteps = steps
        if let pd { pedoDistance = pd }
        // GPS distance when the fix is good, the pedometer's own estimate otherwise (treadmill, tunnels)
        // the Watch's totals take over while they keep coming (Watch mode)
        guard !watchFresh else { update(); return }
        let gps = lastGoodFix.map { Date().timeIntervalSince($0) < 5 } ?? false
        let sample = StepLengthEstimator.Sample(time: Date().timeIntervalSinceReferenceDate,
                                                distance: gps ? gpsDistance : pedoDistance,
                                                steps: steps, source: gps ? .gps : .pedometer)
        estimator.add(sample)
        update()
    }

    private func locationUpdate(_ locs: [CLLocation]) {
        for l in locs {
            guard l.horizontalAccuracy >= 0, l.horizontalAccuracy <= 25 else { continue }
            if let prev = lastLocation {
                let d = l.distance(from: prev), dt = l.timestamp.timeIntervalSince(prev.timestamp)
                guard dt > 0 else { continue }
                if d / dt < 12 { gpsPathDistance += d }      // ignore jumps faster than a sprinter
                // Summing the steps between fixes adds up their wobble (7-9 m fixes made a run
                // 16% too long against the Watch, 2026-11-21); the Doppler speed doesn't wobble.
                if l.speed >= 0, l.speedAccuracy >= 0, l.speedAccuracy <= 2, dt <= 3 { gpsDistance += l.speed * dt }
                else if d / dt < 12 { gpsDistance += d }
            }
            lastLocation = l
            lastGoodFix = Date()
            routeBuffer.append(l)
            elevation.add(altitude: l.altitude, verticalAccuracy: l.verticalAccuracy)
        }
        gpsGood = lastGoodFix.map { Date().timeIntervalSince($0) < 5 } ?? false
        if routeBuffer.count >= 20 { flushRoute() }
    }

    private func flushRoute() {
        guard !routeBuffer.isEmpty else { return }
        if outdoor { health.addRoute(routeBuffer); routePoints += routeBuffer.count }
        routeBuffer.removeAll()
    }

    // MARK: the loop (1 Hz)

    private func update() {
        guard state == .running else { return }
        gpsGood = lastGoodFix.map { Date().timeIntervalSince($0) < 5 } ?? false
        stepLength = estimator.stepLength
        measuredCadence = estimator.cadence
        currentSpeed = estimator.speed ?? (gpsGood ? lastLocation.map { max(0, $0.speed) } : nil)
        distance = watchFresh ? (watchDistance ?? 0) : (gpsDistance > 0 ? gpsDistance : pedoDistance)
        let done = splitTracker.add(distance: distance, at: Date())
        for s in done { log.event("split \(s.unitMeters == 1000 ? "km" : "mi") \(s.index): \(Int(s.end.timeIntervalSince(s.start))) s") }
        splitList += done
        let elapsed = startDate.map { Date().timeIntervalSince($0) } ?? 0
        if paceBy == .heartRate {
            let fresh = heartRateAt.map { Date().timeIntervalSince($0) < 15 } ?? false
            aimSpeed = hrGov.update(heartRate: fresh ? heartRate : nil, time: Date().timeIntervalSinceReferenceDate,
                                    atFloor: clickCadence <= minCadence + 0.5)
            if hrGov.walking != walking { walking = hrGov.walking; walkChanged() }
        } else if let g = goal {
            if distance < g {
                behind = GoalPace.behind(distance: distance, elapsed: elapsed, targetSpeed: targetSpeed)
            } else if !goalReached {
                goalReached = true
                log.event("goal reached: \(Int(elapsed)) s for \(Int(g)) m (target \(Int(g / targetSpeed)) s)")
            }
        }
        if paceBy == .pace { aimSpeed = GoalPace.speed(goal: goal, distance: distance, elapsed: elapsed, targetSpeed: targetSpeed) }
        governor.targetSpeed = aimSpeed ?? targetSpeed
        wantedCadence = governor.desired(stepLength: stepLength)
        clickCadence = governor.update(stepLength: stepLength, time: Date().timeIntervalSinceReferenceDate, hold: holding)
        metronome.bpm = clickCadence
        if let s = stepLength { strideBucket.append(s) }
        if let v = currentSpeed, v > 0.5 { speedBucket.append(v) }
        flushStride(force: false)
        sendStatus(force: false)
        log.row([clickCadence, wantedCadence, stepLength, measuredCadence, currentSpeed, distance, gpsGood,
                 gpsDistance, pedoSteps, pedoDistance, heartRate, holding,
                 lastLocation?.horizontalAccuracy, lastLocation?.altitude, gpsPathDistance, watchDistance, watchSteps,
                 watchFresh ? "watch" : (gpsGood ? "gps" : "pedometer"), aimSpeed, behind])
    }

    /// One running-stride-length sample per minute for Health.
    private func flushStride(force: Bool) {
        let now = Date()
        if lastStrideMinute == nil { lastStrideMinute = now }
        guard let last = lastStrideMinute, force || now.timeIntervalSince(last) >= 60 else { return }
        if !strideBucket.isEmpty { strides.append((now, strideBucket.reduce(0, +) / Double(strideBucket.count))) }
        if !speedBucket.isEmpty { speeds.append((now, speedBucket.reduce(0, +) / Double(speedBucket.count))) }
        strideBucket.removeAll(); speedBucket.removeAll(); lastStrideMinute = now
    }

    private func resetLive() {
        estimator.reset()
        gpsDistance = 0; gpsPathDistance = 0; pedoSteps = 0; pedoDistance = 0; distance = 0
        watchDistance = nil; watchSteps = nil; lastWatchTotals = nil
        lastLocation = nil; lastGoodFix = nil
        stepLength = nil; measuredCadence = nil; currentSpeed = nil; wantedCadence = nil; heartRate = nil
        strides.removeAll(); strideBucket.removeAll(); speeds.removeAll(); speedBucket.removeAll(); lastStrideMinute = nil
        routeBuffer.removeAll()
        holding = false
        behind = nil; aimSpeed = nil; goalReached = false
        if walking { walking = false; metronome.volume = Float(volume) }
        heartRateAt = nil
    }

    /// Heart-rate mode: the click goes quiet for a walk and comes back for running.
    private func walkChanged() {
        metronome.volume = walking ? 0 : Float(volume)
        log.event(walking ? "walk (heart rate \(Int(heartRate ?? 0)))" : "run again (heart rate \(Int(heartRate ?? 0)))")
        let u = AVSpeechUtterance(string: walking ? "Walk for a bit, until your heart rate comes down." : "Heart rate's down. Run easy.")
        u.volume = 1
        speech.speak(u)
        sendStatus(force: true)
    }

    // MARK: settings changes

    private func targetChanged() {
        governor.targetSpeed = targetSpeed
        refitStride()
        sendStatus(force: true)
    }

    private func rangeChanged() {
        guard minCadence < maxCadence else { return }
        governor.range = minCadence...maxCadence
    }

    private func convertTarget(from old: DistanceUnit) {
        targetSeconds = (targetSeconds * unit.meters / old.meters).rounded()
    }

    // MARK: Watch

    private func handle(_ m: RemoteMessage) {
        switch m {
        case .setTarget(let s): targetSeconds = min(max(s, 150), 1200); log.event("watch target \(s)")
        case .setHold(let h): holding = h; log.event("watch hold \(h)")
        case .heartRate(let hr): heartRate = hr
        case .diag(let s): log.event("watch: \(s)")
        case .totals(let d, let s):
            if !watchFresh { log.event("distance from the Watch") }
            watchDistance = d; watchSteps = s; lastWatchTotals = Date()
            estimator.add(.init(time: Date().timeIntervalSinceReferenceDate, distance: d, steps: s, source: .watch))
            update()
        case .status, .discard: break
        }
    }

    private func sendStatus(force: Bool) {
        guard health.isMirrored, force || Date().timeIntervalSince(lastStatusSent) >= 2 else { return }
        lastStatusSent = Date()
        health.send(.status(RunStatus(targetSecondsPerUnit: targetSeconds, unit: unit, clickCadence: clickCadence,
                                      measuredCadence: measuredCadence, currentSecondsPerUnit: currentSecondsPerUnit,
                                      stepLength: stepLength, distance: distance,
                                      elapsed: startDate.map { Date().timeIntervalSince($0) } ?? 0, holding: holding,
                                      goalRemaining: goal.flatMap { $0 > distance ? $0 - distance : nil },
                                      behind: goalReached ? nil : behind,
                                      hrCeiling: paceBy == .heartRate ? hrCeiling : nil,
                                      walking: paceBy == .heartRate ? walking : nil)))
    }

    // MARK: persistence

    @ObservationIgnored private var loading = false

    private func loadSettings() {
        loading = true; defer { loading = false }
        let d = defaults
        if d.object(forKey: "targetSeconds") != nil { targetSeconds = d.double(forKey: "targetSeconds") }
        if let u = d.string(forKey: "unit").flatMap(DistanceUnit.init(rawValue:)) { unit = u }
        if d.object(forKey: "minCadence") != nil { minCadence = d.double(forKey: "minCadence") }
        // the old default of 150 sat above easy paces (10:00/mi at 1.16 m steps needs ~139)
        if !d.bool(forKey: "minCadence140"), minCadence == 150 { minCadence = 140; d.set(140.0, forKey: "minCadence") }
        d.set(true, forKey: "minCadence140")
        if d.object(forKey: "maxCadence") != nil { maxCadence = d.double(forKey: "maxCadence") }
        if d.object(forKey: "startCadence") != nil { startCadence = d.double(forKey: "startCadence") }
        if d.object(forKey: "volume") != nil { volume = d.double(forKey: "volume") }
        if let r = d.string(forKey: "recording").flatMap(Recording.init(rawValue:)) { recording = r }
        else if d.bool(forKey: "useWatch") { recording = .watch }
        if d.object(forKey: "outdoor") != nil { outdoor = d.bool(forKey: "outdoor") }
        goalMeters = d.double(forKey: "goalMeters")
        if let p = d.string(forKey: "paceBy").flatMap(PaceBy.init(rawValue:)) { paceBy = p }
        if d.object(forKey: "hrCeiling") != nil { hrCeiling = d.double(forKey: "hrCeiling") }
        if d.object(forKey: "lowerMusic") != nil { lowerMusic = d.bool(forKey: "lowerMusic") }
    }

    private func saveSettings() {
        guard !loading else { return }
        let d = defaults
        d.set(targetSeconds, forKey: "targetSeconds"); d.set(unit.rawValue, forKey: "unit")
        d.set(minCadence, forKey: "minCadence"); d.set(maxCadence, forKey: "maxCadence")
        d.set(startCadence, forKey: "startCadence"); d.set(volume, forKey: "volume"); d.set(recording.rawValue, forKey: "recording"); d.set(outdoor, forKey: "outdoor"); d.set(lowerMusic, forKey: "lowerMusic"); d.set(goalMeters, forKey: "goalMeters")
        d.set(paceBy.rawValue, forKey: "paceBy"); d.set(hrCeiling, forKey: "hrCeiling")
    }
}

extension RunModel: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.locationUpdate(locations) }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
