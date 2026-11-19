import AVFoundation

/// Sample-accurate click: AVAudioEngine plays a short click buffer at computed sample times, a
/// little ahead of the playhead. Tempo changes take effect from the next beat. The audio session
/// mixes with other audio, so music keeps playing underneath.
final class Metronome: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "dev.sstrabe.stride.metronome", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var click: AVAudioPCMBuffer?
    private var sampleRate: Double = 44_100
    private var nextBeat: Double = 0        // in player sample time
    private var running = false

    private let lock = NSLock()
    private var _bpm: Double = 170
    /// Clicks per minute (one per foot strike).
    var bpm: Double {
        get { lock.withLock { _bpm } }
        set { lock.withLock { _bpm = min(max(newValue, 40), 260) } }
    }

    var volume: Float = 0.8 { didSet { player.volume = volume } }
    var isRunning: Bool { queue.sync { running } }

    init() {
        engine.attach(player)
        let nc = NotificationCenter.default
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.queue.async { self?.restartAfterChange() }
        }
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] n in
            guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.queue.async { self?.restartAfterChange() }
        }
    }

    func start() throws {
        try queue.sync {
            guard !running else { return }
            let s = AVAudioSession.sharedInstance()
            // mixWithOthers: the user's music keeps playing at full volume under the click
            try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try s.setActive(true)
            try startEngine()
            running = true
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(40), leeway: .milliseconds(5))
            t.setEventHandler { [weak self] in self?.scheduleAhead() }
            t.resume()
            timer = t
        }
    }

    func stop() {
        queue.sync {
            guard running else { return }
            running = false
            timer?.cancel(); timer = nil
            player.stop()
            engine.stop()
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - engine (all on `queue`)

    private func startEngine() throws {
        sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if sampleRate <= 0 { sampleRate = 44_100 }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw NSError(domain: "Metronome", code: 1)
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        click = Self.makeClick(format: format)
        player.volume = volume
        engine.prepare()
        try engine.start()
        player.play()
        nextBeat = -1      // set from the playhead on the first tick
    }

    private func restartAfterChange() {
        guard running else { return }
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(true)
        try? startEngine()
    }

    private func playhead() -> Double? {
        guard let nt = player.lastRenderTime, nt.isSampleTimeValid,
              let pt = player.playerTime(forNodeTime: nt) else { return nil }
        return Double(pt.sampleTime)
    }

    private func scheduleAhead() {
        guard running, engine.isRunning, let click, let now = playhead() else { return }
        let lead = 0.06 * sampleRate
        if nextBeat < now + 0.005 * sampleRate { nextBeat = now + lead }   // first tick or fell behind
        let horizon = now + 0.35 * sampleRate
        while nextBeat < horizon {
            let at = AVAudioTime(sampleTime: AVAudioFramePosition(nextBeat.rounded()), atRate: sampleRate)
            player.scheduleBuffer(click, at: at, options: [], completionHandler: nil)
            nextBeat += 60.0 / bpm * sampleRate
        }
    }

    /// A short woodblock-like tick: two decaying sines, 25 ms.
    private static func makeClick(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let n = AVAudioFrameCount(0.025 * sr)
        guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n), let ch = b.floatChannelData?[0] else { return nil }
        b.frameLength = n
        for i in 0..<Int(n) {
            let t = Double(i) / sr
            let env = exp(-t * 180) * min(1, t * sr / 24)       // ~0.5 ms attack, fast decay
            let s = 0.75 * sin(2 * .pi * 1_750 * t) + 0.35 * sin(2 * .pi * 3_100 * t)
            ch[i] = Float(s * env * 0.9)
        }
        return b
    }
}
