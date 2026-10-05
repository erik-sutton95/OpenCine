# OpenCineHarness

Developer-only harness proving that the OpenCine packages compose across brands (plan work
package MULTI-03). **It is not a product and not an app**: nothing here ships, it has no UI, and
**every camera in it is SIMULATED**. It qualifies no hardware combination.

It builds the real `DJICameraSessionAdapter` (OpenCineDJI), `NikonCameraSession`
(OpenCineNikon) and `LunaCameraSession` (OpenCineInsta360) in one process, one dependency
closure, and drives them through OpenCineMulticam. Only the app-side link under each session is
scripted: a `DJIControlPort` and a `NikonControlDriver` in `Tests/HarnessTests/Simulated.swift`,
and OpenCineInsta360's `FakeLuna`, which answers in Luna's real wire encodings.

## Layout

| Target | What it is | May import |
|---|---|---|
| `HarnessEngine` | Neutral code a multi-brand app would add beside OpenCineMulticam: `AnalysisConfiguration` (per-source signal and false-colour reading, plan 6.3), `GroupSyncReport` and `ClockRelationship` (plan 8.3 levels), `MulticamSnapshot.gather` | OpenCineCore, OpenCineMedia, OpenCineMulticam |
| `HarnessComposition` | The composition root: `Composition.factories`, the explicit list of integration factories with their routes and claims (plan 1.3, 9.1: no registry, no plugin loading), typed session constructors, and `ProposedMappings` (adapter additions the findings below propose) | everything |
| `HarnessTests` | Scenario suites, each labelled SIMULATED | everything, plus test support |

Only `HarnessComposition` and the tests name a manufacturer. A test scans `HarnessEngine` and
OpenCineMulticam's sources for vendor and UI names.

## Run

```sh
swift build --build-tests                 # from the repository root
swift test --filter HarnessTests
# optional: everything also builds for iOS
xcodebuild -scheme OpenCine-Package -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

The harness targets live in the platform package beside everything they compose, so there is one
dependency closure by construction (the former `check-closure.sh` is gone). They are targets, not
products: nothing here ships.

Last local run (2026-10-02, Swift 6.2.3, Xcode 26.2, macOS 26, after the findings fix wave):
`swift test` 26 tests in 7 suites passed, no known issues; 0 "implemented in both" warnings;
generic iOS build succeeded. All five packages at the pinned SHAs.

## Scenarios

| Suite | Plan | What it shows (SIMULATED) |
|---|---|---|
| `CompositionTests` | 1.3, 13 MULTI-03 step 1, gate | Factory list; three brands' sessions in one process and one Core type system; closing or replacing one session (or running a second camera of every brand) leaves the others alone; two Luna backends share no credentials or callbacks; neutral code names no manufacturer |
| `EntryTests` | 5.3, 9.3, 11.2 #10 | Capture-only HDMI entry, control-only Nikon entry, two views of one Pocket (one command, one result for both, counted once); replacing a Nikon picture with HDMI keeps the session, epoch and plan; settings need no picture, record keeps its live-view preflight |
| `CapabilityTests` | 5.6, 5.7, 8.3 | Each session describes different controls (no brand branch); undescribed controls stay unknown and are refused before any wire; Nikon native shutter angle versus DJI derived angle provenance; unknown battery, storage and recording stay unknown and block a group start; audio absence fabricates no meter; Luna clock-derived time never establishes a clock relationship and the report has no "synchronized" flag |
| `AnalysisTests` | 6.3, 11.2 #12 | Two D-Log2 sources with LOG and 709 readings and separate live ceilings stay independent; Luna's I-Log signal is stated by the operator, never inferred from its recording profile |
| `GroupRecordTests` | 8.2, 11.2 #8, #13 | `RecordPlan` with one camera confirming, one refusing, one timing out; no compensation; strict refuses while eligible-subset states its exclusions; a replacement session (or a new DJI link) while the confirmation is open makes the plan stale and nothing is sent; a late result never lands on a replacement; lease expiry (Core fake relay) and a Nikon relay viewer taking control block commands but keep the picture |
| `AdmissionTests` | 8.4 | Luna's access point conflicts with a router the others use; two camera access points cannot share a phone; Nikon USB control plus HDMI capture coexist; the qualified count is a budget value |
| `FindingsTests` | 15.6 | F1 regression: one group deadline and one freshness check mean the same instant to every session |

The shared Multiview stage scenarios (`twoMemberStage`, `fourMemberStage`, SIMULATED, over
`FakeIntegration` and the shared engine) live in `OpenCineAppKitTests/MultiviewStageTests` and
Kotlin `appkit` `MultiviewStageTest`, because the harness layer must not depend on the shared UI
(atlas layers). See [appkit](../appkit/README.md#multiview-stage).

Physical combinations: [TOPOLOGY.md](TOPOLOGY.md) (nothing qualified).

## What simulation proves, and what it does not

Proves, for these package revisions:

- The three integrations and OpenCineMulticam link into one binary with one copy of each module
  and one OpenCineCore, on macOS and (build only) iOS.
- The engine needs no manufacturer branch: every scenario runs on Core values and the
  `CameraSession` seam.
- The real adapters' admission, idempotency, receipts, epochs and close semantics hold when
  mixed: partial outcomes stay per camera, nothing is compensated, nothing fabricates a
  reported state.
- Route claims reject the combinations one phone cannot hold.

Does not prove:

- Anything about hardware: pairing, Wi-Fi joins, USB, decode load, real timing, firmware quirks.
  The scripted links answer instantly and deterministically.
- That the app-side ports behave as scripted. Pocket's `CameraSession: DJIControlPort` and
  OpenZCine's `NativeAppModel` are tested in their apps; the scripts follow those contracts.
- Shared UI: OpenCineUI is not composed here; `MonitorLayoutCapabilities` stands in.
- Any network combination in `docs/TOPOLOGY.md`.

## Seam findings

Found by composing the sessions. Status 2026-10-02: F1 and F3 to F7 are fixed in the owning
packages (OpenCineCore 3e60644, OpenCineMulticam 48b0730, OpenCineDJI 15ab51f, OpenCineNikon
ea4bbcd, OpenCineInsta360 f8f4c27); F2 belongs to RELEASE-01 (publish tooling). The original
findings and what changed:

- **F1, three clock references (defect for any cross-brand app).** DJI stamps nothing and checks
  deadlines on a process-relative `ContinuousClock`; Nikon uses a per-session `ContinuousClock`
  reference; Luna uses `ProcessInfo.systemUptime` (which also pauses in sleep). OpenCineMulticam
  compares all of them with one `MulticamSnapshot.now`, so a group deadline 4 s ahead is already
  past for Luna, lease expiry is judged on different clocks, and a fresh Nikon report looks stale
  on Luna's reference. Same-brand apps never see it. Fix: one shared host reference in
  OpenCineCore (for example `MonotonicInstant.now()` over one process-wide `ContinuousClock`,
  injectable per session for tests; Kotlin one `System.nanoTime()` origin), used by every adapter
  and by the app for `MulticamSnapshot.now`; DJI should stamp observations. **Fixed:**
  `MonotonicInstant.now()` (Swift `ContinuousClock` reference, Kotlin `System.nanoTime()`), every
  Swift session takes an injectable `now` defaulting to it, `MulticamSnapshot.now` and `gather`
  default to it; `FindingsTests` are plain regression tests. Not done: DJI still stamps no
  observation time (its `CameraStatus` carries no arrival time), so DJI freshness stays unknown.
- **F2, packages pin different Core revisions (release blocker).** OpenCineMulticam pins Core
  `ada2871`, the three integrations `6b0e6ea`, Core main is `727baa0`. Sibling paths hide it (one
  checkout, verified), but with exact remote versions a cross-brand app could not resolve. Fix
  (RELEASE-01): libraries declare a range on Core (`from:` / `.upToNextMinor`); only apps pin
  exactly via `Package.resolved`. **Resolved by the consolidation:** every product now ships from
  one package at one version, so there is no cross-package Core range to reconcile.
- **F3, DJI audio meters default to silence.** `CameraStatus.audioMeters` is `.silent` before any
  audio push, indistinguishable from a silent input. Core had no audio vocabulary, so nothing
  shared showed it. Fix: publish `ObservedValue<AudioMeterLevels>`, unknown until
  `audioStatusRaw` arrives. **Fixed:** `audioMeters` is
  `nil` until the camera reports. Core now has `CameraSnapshot.audioLevels` with
  `CapabilitySnapshot.audioLevels` support, and the DJI session publishes both (SHELL-01).
- **F4, shutter unpublished and a fabricating helper.** DJI and Nikon sessions do not describe
  shutter. `ShutterAngle.degrees(denom:fps:)` (OpenCineMedia) answers 180 for a non-positive
  denominator and treats an unknown frame rate as 24. Fix: Nikon publishes `.angle`
  (camera-reported) in angle mode, DJI its native `.duration` with any angle readout marked
  `.protocolDerived`; the helper returns `Double?` or callers guard
  (`ProposedMappings.djiShutterAngle`). **Fixed (helper):** `degrees(denom:fps:)` and
  `nearestLabel(denom:fps:)` return `nil` for an unknown 1/N or rate. Publishing shutter from the
  DJI and Nikon sessions is still open.
- **F5, integration IDs isolated to the main actor on DJI and Nikon** (Luna's is `nonisolated`),
  so the composition root must be `@MainActor`. Fix: `public nonisolated static let integration`.
  **Fixed:** `Composition.factories` is nonisolated; only the session constructors are main-actor.
- **F6, nothing is declared unsupported.** No adapter fills `CapabilitySnapshot.unsupported`
  (fixed apertures on Pocket and Luna, no tint in the Nikon slice), so shared UI cannot tell "no
  iris" from "not discovered". Fix: each adapter lists what the body cannot do. **Fixed:** DJI
  lists aperture, focus mode, tap focus and zoom from the connected `CameraModel`'s flags (port
  `connectedModel`; unknown body claims nothing), Luna lists aperture; Nikon knows of no absent
  control (every common key exists on Z bodies), so nothing is listed.
- **F7, DJI look curves on the neutral namespace.** OpenCineDJI extends OpenCineMedia's
  `LiveColorScience` with `rec709LookCurve(_:)` keyed by the shared `MonitorTransfer`, `.ilog`
  included. Fix: a DJI-named namespace; each integration supplies its look per source (as
  `AnalysisConfiguration.lookCurve` does). **Fixed:** `DJILook` in OpenCineDJI.

Recorded for scope, not defects: no vendor session offers lease authority yet (lease expiry uses
Core's fake relay plus Nikon's real "relay viewer holds control" path); OpenCineMulticam models
neither plan 8.3 synchronization levels nor plan 6.3 per-source analysis, so `GroupSyncReport`
and `AnalysisConfiguration` here are proposals for those homes.

## Android

No Kotlin harness yet: the Kotlin DJI session (`PocketControlPort` and its adapter) and the Kotlin
Nikon session still live in their apps, and only the Core, Multicam and Insta360 areas
(`:core`, `:media`, `:multicam`, `:insta360-shell`, `:insta360-luna`) have Gradle modules. A Kotlin harness would
need:

1. A DJI module in `Android/` with the Kotlin `DjiCameraSessionAdapter` over `PocketControlPort` (blocked
   on app-package imports in `PocketCameraSession.kt` and the fixed JNI class name, VENDOR-01).
2. A Nikon module in `Android/` with the Kotlin Nikon session over its control-driver port and the JNI
   facade (`PTPIPClientSession`, `AndroidSessionOwnerRegistry`, VENDOR-02 follow-up).
3. A JVM-testable Luna session: `:insta360-luna` is an Android library, so either Robolectric or
   splitting `LunaCameraSession` and its wire code into a JVM module with a fake link like
   `FakeLuna`.
4. A harness test module in the platform Gradle build depending on those modules by project, and
   the same scenarios mirrored by name, as Core and Multicam already do.
5. A native closure check: the DJI and Nikon JNI facades each link a Swift Android runtime and
   OpenCineCore; one APK must carry one copy of each `.so` and no colliding `JNI_OnLoad` (plan
   15.6, "native/Android packaging has a coherent dependency closure").
6. F1 in Kotlin: Core `MonotonicInstant.now()` is `System.nanoTime()`; the Kotlin Luna session
   already stamps that. The app-side Kotlin DJI and Nikon adapters move to it on their app
   `opencine/integration` branches.

## Gate (plan 13, MULTI-03)

| Gate | Result |
|---|---|
| Shared engine/UI requires no manufacturer branch | Engine: met (scan test; Core and Multicam enforce their own rules). UI: not exercised (OpenCineUI not composed). |
| No global runtime collision | Met in simulation for state, credentials and clocks (F1 fixed: one host clock); Luna's camera access point is process-wide by design (admission rejects a second). |
| Unsupported physical combinations rejected or documented | Met: `AdmissionTests` plus `docs/TOPOLOGY.md`. |
| Evidence distinguishes simulation from hardware | Met: every suite, this README and the matrix say SIMULATED or untested; no hardware run exists. |

## License

Apache 2.0 (LICENSE, NOTICE).
