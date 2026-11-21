import Testing
import Foundation

@Test func targetPaceToSpeed() {
    let v = Pace.speed(secondsPer: 502, unit: .mile)   // 8:22/mi
    #expect(abs(v - 3.2059) < 0.001)
    #expect(Pace.format(502) == "8:22")
    #expect(Pace.format(Pace.seconds(speed: v, unit: .mile)) == "8:22")
    #expect(Pace.format(nil) == "–:––")
}

@Test func requiredCadence() {
    let v = Pace.speed(secondsPer: 502, unit: .mile)
    // 8:22/mi with 1.10 m steps: about 175 spm
    #expect(abs(Cadence.required(speed: v, stepLength: 1.10) - 174.9) < 0.1)
    // longer steps need fewer of them
    #expect(Cadence.required(speed: v, stepLength: 1.2) < Cadence.required(speed: v, stepLength: 1.0))
}

@Test func stepLengthFromWindow() {
    var e = StepLengthEstimator()
    #expect(e.stepLength == nil)
    // 3 steps/s at 1.1 m per step for 30 s
    for t in 0...30 {
        e.add(.init(time: Double(t), distance: Double(t) * 3.3, steps: Double(t) * 3, source: .gps))
    }
    #expect(abs(e.stepLength! - 1.1) < 1e-9)
    #expect(abs(e.cadence! - 180) < 1e-9)
    #expect(abs(e.speed! - 3.3) < 1e-9)
    // the window keeps only the recent past
    #expect(e.samples.first!.time >= 30 - e.window - 1)
}

@Test func estimatorFollowsChange() {
    var e = StepLengthEstimator()
    for t in 0...20 { e.add(.init(time: Double(t), distance: Double(t) * 3.0, steps: Double(t) * 3, source: .gps)) }
    #expect(abs(e.stepLength! - 1.0) < 1e-9)
    var d = 60.0, s = 60.0
    for t in 21...40 { d += 3.6; s += 3; e.add(.init(time: Double(t), distance: d, steps: s, source: .gps)) }
    #expect(abs(e.stepLength! - 1.2) < 1e-9)
}

@Test func estimatorResetsOnSourceChange() {
    var e = StepLengthEstimator()
    for t in 0...20 { e.add(.init(time: Double(t), distance: Double(t) * 3, steps: Double(t) * 3, source: .gps)) }
    e.add(.init(time: 21, distance: 5, steps: 63, source: .pedometer))
    #expect(e.samples.count == 1)
    #expect(e.stepLength == nil)
}

@Test func implausibleStepLengthIgnored() {
    var e = StepLengthEstimator()
    // GPS jump: 30 m per step
    for t in 0...20 { e.add(.init(time: Double(t), distance: Double(t) * 90, steps: Double(t) * 3, source: .gps)) }
    #expect(e.stepLength == nil)
}

@Test func governorSlewsAndClamps() {
    let v = Pace.speed(secondsPer: 502, unit: .mile)
    var g = CadenceGovernor(targetSpeed: v, startCadence: 170)
    #expect(g.cadence == 170)
    g.update(stepLength: 1.10, time: 0)            // first update: no time passed
    #expect(g.cadence == 170)
    g.update(stepLength: 1.10, time: 10)           // 10 s at 0.3 spm/s: +3
    #expect(abs(g.cadence - 173) < 1e-9)
    g.update(stepLength: 1.10, time: 100)          // settles at the required 174.9
    #expect(abs(g.cadence - 174.9) < 0.1)
    g.update(stepLength: 0.5, time: 1000)          // would be 385: clamped
    #expect(g.cadence == 200)
    g.update(stepLength: nil, time: 2000)          // no measurement: stays
    #expect(g.cadence == 200)
    g.update(stepLength: 1.10, time: 3000, hold: true)
    #expect(g.cadence == 200)
}

@Test func remoteMessageRoundTrip() {
    let s = RunStatus(targetSecondsPerUnit: 502, unit: .mile, clickCadence: 175, measuredCadence: 172,
                      currentSecondsPerUnit: 510, stepLength: 1.1, distance: 1234, elapsed: 600, holding: false)
    guard case .status(let back)? = RemoteMessage.decode(RemoteMessage.status(s).encoded()!) else {
        Issue.record("no round trip"); return
    }
    #expect(back == s)
}

@Test func strideFitBySpeed() {
    // stride = 0.5 + 0.2 × speed, speeds 2.5…4.4 m/s
    let pts = (0..<40).map { i -> StrideFit.Point in
        let v = 2.5 + Double(i) * 0.05
        return .init(speed: v, stride: 0.5 + 0.2 * v)
    }
    let e = StrideFit.estimate(at: 3.206, points: pts)!
    #expect(e.bySpeed)
    #expect(abs(e.stride - (0.5 + 0.2 * 3.206)) < 1e-9)
    // far outside the speeds run: clamped to max + 0.5
    let far = StrideFit.estimate(at: 6.9, points: pts)!
    #expect(abs(far.stride - (0.5 + 0.2 * (2.5 + 39 * 0.05 + 0.5))) < 1e-9)
}

@Test func strideFitFallsBackToMedian() {
    // all at one speed: no line, median instead
    let pts = [1.0, 1.1, 1.2, 1.05, 1.15].map { StrideFit.Point(speed: 3, stride: $0) }
    let e = StrideFit.estimate(at: 3.5, points: pts)!
    #expect(!e.bySpeed)
    #expect(abs(e.stride - 1.1) < 1e-9)
    #expect(StrideFit.estimate(at: 3, points: Array(pts.prefix(2))) == nil)       // too few
    #expect(StrideFit.estimate(at: 3, points: [], strides: [1.0, 1.2, 1.1, 5.0, 1.3, 0.9])!.stride == 1.1)
}

@Test func stridePairing() {
    let t0 = Date(timeIntervalSinceReferenceDate: 0)
    let strides = [(t0, 1.1), (t0.addingTimeInterval(100), 1.2), (t0.addingTimeInterval(1000), 1.3)]
    let speeds = [(t0.addingTimeInterval(110), 3.5), (t0.addingTimeInterval(5), 3.0)]
    let r = StrideFit.pair(strides: strides, speeds: speeds)
    #expect(r.points == [.init(speed: 3.0, stride: 1.1), .init(speed: 3.5, stride: 1.2)])
    #expect(r.unpaired == [1.3])
}

@Test func splitsPerKilometreAndMile() {
    let t0 = Date(timeIntervalSince1970: 0)
    var s = SplitTracker(start: t0)
    var all: [SplitTracker.Split] = []
    // 3.2 m/s, a reading every 10 s for 20 minutes (3840 m)
    for i in 1...120 { all += s.add(distance: Double(i) * 32, at: t0.addingTimeInterval(Double(i) * 10)) }
    let km = all.filter { $0.unitMeters == 1000 }, mi = all.filter { $0.unitMeters != 1000 }
    #expect(km.count == 3 && mi.count == 2)
    #expect(abs(km[0].end.timeIntervalSince(t0) - 312.5) < 0.01)   // 1000 m / 3.2 m/s
    #expect(km[1].start == km[0].end)
    let rest = s.finish(at: t0.addingTimeInterval(1200))
    #expect(rest.count == 2 && rest.allSatisfy(\.partial))
    #expect(rest.first { $0.unitMeters == 1000 }?.index == 4)
}

@Test func elevationIgnoresNoise() {
    var e = ElevationTracker()
    for i in 0..<200 { e.add(altitude: 100 + (i % 2 == 0 ? 1 : -1), verticalAccuracy: 5) }
    #expect(e.ascended == 0)
    for i in 0..<100 { e.add(altitude: 100 + Double(i) * 0.5, verticalAccuracy: 5) }   // climb ~50 m
    #expect(e.ascended > 40 && e.ascended < 52)
}
