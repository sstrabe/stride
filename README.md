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
- **Goal distance** (optional, e.g. 1 mile): the click aims for the whole distance at the target
  pace. Behind schedule it asks for up to 12% more speed, ahead up to 12% less
  (`GoalPace`); after the goal it goes back to the plain target. The iPhone and the Watch show
  what's left and how far ahead or behind you are.
- **Health and Fitness**:
  - *iPhone only* (default): a HealthKit workout session on the iPhone (iOS 26). It records an
    outdoor run with its GPS route, distance, active energy, and a running stride length sample
    for each minute.
  - *Stride on Apple Watch* (Settings, Record with): the iPhone starts the Watch app, and the Watch runs the
    workout and mirrors it to the iPhone. You get rings and heart rate, and the workout lands in
    Fitness. The iPhone still measures and clicks. The Watch shows the click tempo, target and
    current pace, heart rate and time. Turn the Digital Crown to change the target pace. You can
    also start a run on the Watch itself.
  - *Workout app on Watch*: start the run in Apple's Workout app, then Start in Stride. Stride
    starts no workout of its own (a second one on the Watch would end the Workout app's, one on
    the iPhone would put the run in Fitness twice) and only clicks; the Workout app records
    everything. Stride can't read that session, so the Watch shows no click tempo.

- **What a Watch run saves** (matched against an export of Apple's Workout app runs, 2026-11-21):
  heart rate, active and basal energy, distance, running form (power, stride length, ground
  contact time, vertical oscillation, speed: the live data source collects them once
  authorized), the GPS route with altitude, elevation ascended/descended, km and mile splits as
  two series of segment events, time zone, indoor/outdoor. Not matched: weather (needs
  WeatherKit, a paid account) and average METs. Physical effort and VO₂ max come from the Watch
  itself. The iPhone-only mode saves the same minus heart rate and running form.

## Diagnostics

- **Run log**: every run, in every mode, writes `Documents/diagnostics/run-<epoch>.json` on the
  iPhone: settings, events (mirroring, splits, the Watch's own report lines) and one row per
  second (click, wanted tempo, step length, cadence, speed, distance, GPS, heart rate).
- **Watch report**: the Watch sends authorization gaps, the types it collects, route points and
  splits to the iPhone's log, puts the last 30 lines in the workout's `StrideDiag` metadata, and
  resends the previous run's finish result at the next start.
- **Health export**: Settings → Export diagnostics, or the `-export` launch argument, dumps the
  last 3 days of workouts from every app (statistics, events, metadata, samples by source,
  routes) to `Documents/diagnostics/export-<epoch>.json`. Pull everything over USB:
  `xcrun devicectl device copy from --device <id> --domain-type appDataContainer
  --domain-identifier dev.sstrabe.stride --source Documents/diagnostics --destination <dir>`.
  Also visible in Files → On My iPhone → Stride.

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

## Icon

`Design/icon.svg` is the source. It's rendered to `Design/icon-1024.png` with
`rsvg-convert -w 1024 -h 1024 -b "#E5341D"` (opaque: iOS refuses alpha), then copied into
`Design/PhoneIcon.xcassets` and `Design/WatchIcon.xcassets`. The iPhone also has a dark and a tinted
variant (`icon-dark.svg`, `icon-tinted.svg`: no background, iOS draws its own), rendered without
`-b` to `icon-dark-1024.png` / `icon-tinted-1024.png` and copied in as `icon-dark.png` /
`icon-tinted.png`. Watch icons have no appearances (always on black). actool needs a simulator runtime, and
the build Mac keeps none (disk), so the `icons` workflow compiles both catalogs on GitHub. Run it,
download its artifact, and commit `Assets.car` (plus the iPhone's `AppIcon60x60@2x.png`) to
`Phone/Icon/` and `Watch/Icon/`.
