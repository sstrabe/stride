# Stride

A running metronome for iPhone and Apple Watch. You set a target pace (say 8:22/mi). Stride
measures your current step length and clicks in your headphones at the cadence that pace needs at
that step length. Put your feet down on the click and you run the target pace. Your music keeps
playing underneath.

```
click (steps/min) = target speed (m/s) × 60 ÷ step length (m)
8:22/mi = 3.206 m/s; at 1.10 m per step → 175 spm
```

- **Step length** = distance ÷ steps over the last 15 s. Distance comes from GPS while the fix is
  good, otherwise from the step counter's own estimate (treadmill, tunnels). Steps come from the
  iPhone's pedometer (CoreMotion).
- **The click moves gently**: at most 0.3 spm per second (3 spm per 10 s), within 150–200 spm
  (adjustable). The click shapes how you run, so a fast-moving tempo would chase its own effect.
  Until the first measurement it starts at the cadence the target pace needs at your **usual step
  length from Apple Health**: running stride length and running speed samples from the last 90 days
  (the Watch writes both on every run), paired by time, with a line fitted through stride against
  speed (`Shared/StrideFit.swift`). With little data it uses the median stride, and with none the
  start tempo from Settings (170 spm). Stride's own runs write both values back each minute. **Hold this tempo** freezes it.
- **Audio**: AVAudioEngine schedules every click at an exact sample time, a little ahead of the
  playhead. The session mixes with other audio (music at full volume) and keeps playing with the
  screen off.
- **Health and Fitness**:
  - *iPhone only* (default): a HealthKit workout session on the iPhone (iOS 26). It records an
    outdoor run with its GPS route, distance, active energy, and a running stride length sample
    for each minute.
  - *Record on Apple Watch* (Settings): the iPhone starts the Watch app, and the Watch runs the
    workout and mirrors it to the iPhone. You get rings and heart rate, and the workout lands in
    Fitness. The iPhone still measures and clicks. The Watch shows the click tempo, target and
    current pace, heart rate and time. Turn the Digital Crown to change the target pace. You can
    also start a run on the Watch itself.

## Layout

| | |
|---|---|
| `Shared/Cadence.swift` | pace/speed maths, `StepLengthEstimator`, `CadenceGovernor` (unit-tested) |
| `Shared/RemoteMessage.swift` | iPhone ⇄ Watch messages over the mirrored workout session |
| `Phone/Metronome.swift` | sample-accurate click engine |
| `Phone/RunModel.swift` | GPS + pedometer → step length → tempo; run lifecycle |
| `Phone/Health.swift` | HealthKit workout on the iPhone, or the mirror of the Watch's |
| `Phone/ContentView.swift` | UI: target pace picker, click tempo, live numbers, settings |
| `Phone/SelfTest.swift` | `-selftest` launch argument: silent click-engine check on a device |
| `Watch/` | Watch app: workout session, mirroring, run screen |
| `Tests/` | Swift Testing on the shared maths (GitHub Actions, simulator) |

## Build

XcodeGen (`project.yml`); the `.xcodeproj` is generated. CI runs the tests on every push.
Device builds go through Sam's `appbuild` tools with `sdk=auto`, so the embedded Watch app is
built for watchOS:

```
build(repo="https://github.com/sstrabe/stride", sdk="auto", install="default", launch=true)
```

Free Personal Team: HealthKit works. The clinical-records key (`healthkit.access`) is refused, so
it isn't used.
