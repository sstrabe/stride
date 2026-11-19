import Foundation
import AVFoundation
import CoreMotion
import CoreLocation
import HealthKit

/// `-selftest` launch argument: runs the click silently for a few seconds at 175 spm and prints
/// what it scheduled, so a device build can be checked from the Mac (devicectl --console).
enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("-selftest") }

    static func run() {
        Task.detached {
            func log(_ s: String) { print("SELFTEST \(s)"); fflush(stdout) }
            log("health available: \(HKHealthStore.isHealthDataAvailable())")
            log("step counting: \(CMPedometer.isStepCountingAvailable()) cadence: \(CMPedometer.isCadenceAvailable())")
            log("location auth: \(CLLocationManager().authorizationStatus.rawValue)")
            let health = await Health()
            let (st, sp) = await health.recentStrideAndSpeed()
            let r = StrideFit.pair(strides: st, speeds: sp)
            let e = StrideFit.estimate(at: Pace.speed(secondsPer: 502, unit: .mile), points: r.points, strides: r.unpaired)
            log("health: \(st.count) stride + \(sp.count) speed samples, \(r.points.count) paired; 8:22/mi -> \(e.map { String(format: "%.3f m (%@)", $0.stride, $0.bySpeed ? "by speed" : "median") } ?? "none")")
            let m = Metronome()
            m.volume = 0
            m.bpm = 175
            do { try m.start() } catch { log("audio start failed: \(error)"); return }
            try? await Task.sleep(for: .seconds(6))
            m.bpm = 180
            try? await Task.sleep(for: .seconds(4))
            let st = m.stats
            m.stop()
            // 6 s at 175 + 4 s at 180 + 0.35 s look-ahead: about 30 beats
            log("beats \(st.beats) span \(String(format: "%.3f", st.span)) s rate \(st.sampleRate)")
            log("route: \(AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue))")
            log("done")
        }
    }
}
