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
