import SwiftUI

struct ContentView: View {
    @Environment(RunModel.self) private var run
    @State private var pickingPace = false
    @State private var showSettings = false
    @State private var confirmStop = false

    var body: some View {
        @Bindable var run = run
        NavigationStack {
            VStack(spacing: 20) {
                targetCard
                clickCard
                if run.state == .running { liveGrid }
                Spacer(minLength: 0)
                controls
            }
            .padding()
            .navigationTitle("Stride")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .disabled(run.state != .idle)
                }
            }
            .sheet(isPresented: $pickingPace) { PacePicker(seconds: $run.targetSeconds, unit: run.unit) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .confirmationDialog("End run?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("End and save") { Task { await run.stop() } }
                Button("Discard run", role: .destructive) { Task { await run.stop(discard: true) } }
            }
        }
        .task { await run.prepare() }
    }

    private var targetCard: some View {
        Button { pickingPace = true } label: {
            VStack(spacing: 4) {
                Text("Target pace").font(.subheadline).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Pace.format(run.targetSeconds)).font(.system(size: 56, weight: .bold, design: .rounded))
                    Text(run.unit.paceSuffix).font(.title3).foregroundStyle(.secondary)
                }
                if let now = run.currentSecondsPerUnit, run.state == .running {
                    let diff = now - run.targetSeconds
                    Text("now \(Pace.format(now)) · \(diff > 0 ? "+" : "−")\(Int(abs(diff).rounded())) s")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(abs(diff) <= 5 ? .green : (diff > 0 ? .orange : .blue))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
        .accessibilityHint("Change the target pace")
    }

    private var clickCard: some View {
        VStack(spacing: 4) {
            Text("Click").font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(run.clickCadence.rounded()))")
                    .font(.system(size: 72, weight: .heavy, design: .rounded))
                    .contentTransition(.numericText())
                Text("spm").font(.title3).foregroundStyle(.secondary)
            }
            .animation(.default, value: Int(run.clickCadence.rounded()))
            if run.state == .running {
                if run.holding {
                    Text("Held").font(.subheadline).foregroundStyle(.orange)
                } else if let want = run.wantedCadence, abs(want - run.clickCadence) >= 1 {
                    Text("moving to \(Int(want.rounded())) for your stride").font(.subheadline).foregroundStyle(.secondary)
                } else if run.stepLength == nil {
                    Text("measuring your stride…").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Group {
                    if let h = run.healthStride {
                        Text("your usual \(String(format: "%.2f", h.stride)) m step at this pace (Apple Health); then follows your stride")
                    } else {
                        Text("starts at \(Int(run.startCadence)), then follows your stride")
                    }
                }
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
    }

    private var liveGrid: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                Stat(label: "Step", value: run.stepLength.map { String(format: "%.2f m", $0) } ?? "–")
                Stat(label: "Your cadence", value: run.measuredCadence.map { "\(Int($0.rounded())) spm" } ?? "–")
            }
            GridRow {
                Stat(label: "Distance", value: String(format: "%.2f %@", run.distance / run.unit.meters, run.unit.short))
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Stat(label: "Time", value: elapsed(ctx.date))
                }
            }
            if let hr = run.heartRate {
                GridRow { Stat(label: "Heart rate", value: "\(Int(hr.rounded())) bpm"); Color.clear }
            }
        }
    }

    private func elapsed(_ now: Date) -> String {
        guard let s = run.startDate else { return "0:00" }
        let t = Int(now.timeIntervalSince(s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    private var controls: some View {
        @Bindable var run = run
        return VStack(spacing: 14) {
            if run.state == .running {
                Toggle("Hold this tempo", isOn: $run.holding)
            }
            HStack {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: $run.volume, in: 0.05...1)
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if run.state == .idle {
                    Button(run.previewing ? "Stop click" : "Try click") { run.togglePreview() }
                        .buttonStyle(.bordered).controlSize(.large)
                }
                Button {
                    if run.state == .idle { Task { await run.start() } } else { confirmStop = true }
                } label: {
                    Text(buttonTitle).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .tint(run.state == .idle ? .green : .red)
                .disabled(run.state == .finishing)
            }
            VStack(spacing: 2) {
                if !run.recordingOn.isEmpty { Text(run.recordingOn) }
                if let m = run.message { Text(m).foregroundStyle(.orange) }
                if run.state == .running && !run.gpsGood { Text("No GPS fix: using the step counter's distance") }
            }
            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private var buttonTitle: String {
        switch run.state {
        case .idle: "Start run"
        case .starting: "Starting…"
        case .running: "End run"
        case .finishing: "Saving…"
        }
    }
}

private struct Stat: View {
    let label: String, value: String
    var body: some View {
        VStack(spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
    }
}

struct PacePicker: View {
    @Binding var seconds: Double
    let unit: DistanceUnit
    @Environment(\.dismiss) private var dismiss
    @State private var min = 8
    @State private var sec = 22

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                Picker("Minutes", selection: $min) {
                    ForEach(3...20, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.wheel)
                Text(":").font(.title)
                Picker("Seconds", selection: $sec) {
                    ForEach(0..<60, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
                .pickerStyle(.wheel)
                Text(unit.paceSuffix).font(.title3).foregroundStyle(.secondary).padding(.trailing)
            }
            .padding()
            .navigationTitle("Target pace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") { seconds = Double(min * 60 + sec); dismiss() }
                }
            }
        }
        .presentationDetents([.height(320)])
        .onAppear { let s = Int(seconds.rounded()); min = s / 60; sec = s % 60 }
    }
}

struct SettingsView: View {
    @Environment(RunModel.self) private var run
    @Environment(\.dismiss) private var dismiss
    @State private var exporting = false
    @State private var shareItems: [URL]?

    var body: some View {
        @Bindable var run = run
        NavigationStack {
            Form {
                Section {
                    Picker("Pace in", selection: $run.unit) {
                        Text("min per mile").tag(DistanceUnit.mile)
                        Text("min per km").tag(DistanceUnit.kilometer)
                    }
                }
                Section {
                    Stepper("Start at \(Int(run.startCadence)) spm", value: $run.startCadence, in: 120...220, step: 1)
                    Stepper("Never below \(Int(run.minCadence)) spm", value: $run.minCadence, in: 100...(run.maxCadence - 5), step: 1)
                    Stepper("Never above \(Int(run.maxCadence)) spm", value: $run.maxCadence, in: (run.minCadence + 5)...240, step: 1)
                } header: { Text("Click tempo") } footer: {
                    Text("The click starts at the cadence your target pace needs at your usual step length in Apple Health (stride length and speed from your past runs); without Health data, at the start tempo. Once your stride is measured it moves to the cadence your target pace needs at that stride, at most 3 spm per 10 seconds.")
                }
                Section {
                    Picker("Record with", selection: $run.recording) {
                        Text("iPhone").tag(RunModel.Recording.phone)
                        Text("Stride on Apple Watch").tag(RunModel.Recording.watch)
                        Text("Workout app on Watch").tag(RunModel.Recording.workoutApp)
                    }
                } header: { Text("Recording") } footer: {
                    switch run.recording {
                    case .phone: Text("The iPhone records the run to Health and Fitness.")
                    case .watch: Text("Stride's Watch app records the workout (heart rate, rings) and shows the click tempo; the iPhone plays the click.")
                    case .workoutApp: Text("Start the run in the Workout app on your Watch, then Start here. The Workout app records it; Stride only clicks.")
                    }
                }
                Section {
                    Button(exporting ? "Exporting…" : "Export diagnostics") {
                        exporting = true
                        Task {
                            if let u = await Export.run() { shareItems = [u] + RunLog.list().suffix(5) }
                            exporting = false
                        }
                    }
                    .disabled(exporting)
                    if let items = shareItems {
                        ShareLink(items: items) { Label("Share \(items.count) files", systemImage: "square.and.arrow.up") }
                    }
                } footer: {
                    Text("Recent workouts from Health (every app) and Stride's run logs, as JSON. Also in Files → On My iPhone → Stride.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
