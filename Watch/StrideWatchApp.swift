import SwiftUI
import WatchKit
import HealthKit

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    /// The iPhone app starts the run here (HKHealthStore.startWatchApp).
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Task { @MainActor in await WatchWorkout.shared.start(workoutConfiguration) }
    }
}

@main
struct StrideWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup { WatchRunView() }
    }
}

struct WatchRunView: View {
    @State private var w = WatchWorkout.shared
    @State private var target: Double = 502
    @State private var lastCrown = Date.distantPast
    @State private var confirmEnd = false

    var body: some View {
        Group {
            if w.running { runningView } else { idleView }
        }
        .task { await w.requestAuthorization() }
        .onChange(of: w.status?.targetSecondsPerUnit) { _, new in
            // follow the phone unless the crown was turned a moment ago
            if let new, Date().timeIntervalSince(lastCrown) > 3 { target = new }
        }
    }

    private var idleView: some View {
        VStack(spacing: 8) {
            Text("Stride").font(.headline)
            Button("Outdoor run") { Task { await w.start(RunTypes.configuration(outdoor: true)) } }
                .buttonStyle(.borderedProminent).tint(.green)
            Button("Indoor run") { Task { await w.start(RunTypes.configuration(outdoor: false)) } }
            Text("The iPhone plays the click").font(.footnote).foregroundStyle(.secondary)
            if let s = w.saved { Text(s).font(.footnote) }
            if let m = w.message { Text(m).font(.footnote).foregroundStyle(.orange) }
        }
    }

    private var runningView: some View {
        let st = w.status
        let unit = st?.unit ?? .mile
        return ScrollView {
            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(st.map { "\(Int($0.clickCadence.rounded()))" } ?? "–")
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                    Text("spm").font(.footnote).foregroundStyle(.secondary)
                }
                HStack {
                    VStack(alignment: .leading) {
                        Text("Target").font(.caption2).foregroundStyle(.secondary)
                        Text("\(Pace.format(target))\(unit.paceSuffix)").font(.body.monospacedDigit())
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("Now").font(.caption2).foregroundStyle(.secondary)
                        Text(Pace.format(st?.currentSecondsPerUnit)).font(.body.monospacedDigit())
                    }
                }
                .focusable()
                .digitalCrownRotation($target, from: 150, through: 1200, by: 1, sensitivity: .low,
                                      isContinuous: false, isHapticFeedbackEnabled: true)
                .onChange(of: target) { old, new in
                    guard old != new, Date().timeIntervalSince(lastCrown) >= 0 else { return }
                    if st.map({ abs($0.targetSecondsPerUnit - new) >= 1 }) ?? true {
                        lastCrown = Date()
                        w.setTarget(new.rounded())
                    }
                }
                HStack {
                    Text(w.heartRate.map { "♥ \(Int($0.rounded()))" } ?? "♥ –")
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(elapsed(ctx.date)).monospacedDigit()
                    }
                }
                .font(.footnote)
                if let left = st?.goalRemaining {
                    let b = st?.behind ?? 0
                    Text(String(format: "%.2f %@ · ", left / unit.meters, unit.short) + (abs(b) < 3 ? "on time" : "\(Int(abs(b).rounded()))s \(b > 0 ? "behind" : "ahead")"))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(abs(b) < 3 ? .green : (b > 0 ? .orange : .blue))
                }
                if !w.phoneConnected { Text("iPhone not connected").font(.footnote).foregroundStyle(.orange) }
                HStack {
                    Button(st?.holding == true ? "Release" : "Hold") { w.setHold(!(st?.holding ?? false)) }
                    Button("End") { confirmEnd = true }.tint(.red)
                }
            }
        }
        .confirmationDialog("End run?", isPresented: $confirmEnd) {
            Button("End and save") { w.end() }
        }
    }

    private func elapsed(_ now: Date) -> String {
        guard let s = w.startDate else { return "0:00" }
        let t = Int(now.timeIntervalSince(s))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}
