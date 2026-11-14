# Shared Multiview: plan series

**Spec:** `docs/superpowers/specs/2026-11-13-shared-multiview-design.md`

The spec's eight steps touch three apps on two platforms, and each later step's exact interfaces
come out of the step before it. So the work is a series of plans; each is written in full when
its predecessor has landed, from the code as it then stands. Every plan leaves every app
working. Nothing is pushed, merged or pinned without the owner.

| Plan | Spec steps | Delivers | Gate |
|---|---|---|---|
| 0 | prerequisite | OpenCine `feat/insta360-multicam` (serial-checked Luna station search, `stationHostsInUse`, `SharedWiFiPath` owners, `LunaMulticamPolicy`) as its own fix PR | owner review; Android one-camera Luna connect on hardware |
| 1 | 1, 2 (part) | Swift `RecordAll`, Swift `SharedNetworkStore`, iOS `lockedNetwork`, shared `MultiviewStageJournal`; Pocket iOS adopts with no visible change; Pocket Android adopts and takes the iOS toolbar order, tally and format line | Pocket Multiview unit and UI suites |
| 2 | 1 (provisioner), 3 | `StationCommissioner`, `StationHostPath`, `MultiviewMemberLink` (integration or app supplied); Pocket iOS provisioner moved into `OpenCineDJIApple`; DJI implementations; Pocket calls through them | Pocket suites |
| 3 | 2 (rest), 4 | AppKit `MultiviewCoordinator` (both platforms); Pocket's `MultiviewSession` becomes an adapter; remaining iOS/Android differences settled to iOS (tile status and actions, discovery demand, probe width, recovery, storage) | Pocket suites, parity tests |
| 4 | 5 | Screen and settings popup composition behind `MultiviewHost` | Pocket hardware pass, iOS and Android (live checklist) |
| 5 | 6, 8 (Luna) | Luna return-to-access-point, LAN-first reconnect, nearby-onto-station target; OpenInstaCine on the shared Multiview (replaces the Z-style stage on `feat/multicam`); handbook | Luna hardware pass, iOS and Android, before merge (owner) |
| 6 | 7, 8 (Nikon) | Swift `NikonDiscovery.excludedHosts`, passive-discovery add, tone polling for Auto LUT; OpenZCine on the shared Multiview; handbook | Nikon hardware pass, iOS and Android, before merge (owner) |

Plan 0 is independent of 1 to 4 and can land any time. Plans 5 and 6 can run in parallel once
plan 4 has landed.

## Carried from Plan 1 (2026-11-13)

Plan 1 landed on `feat/shared-multiview-1` (OpenCine and OpenPocketCine). For the later plans:

- Plan 2/3: locked Shared Wi-Fi page Done should call an explicit "complete" (today it calls the
  wizard's `close`, which in Pocket can cancel Multiview when no network is configured); take its
  accessibility id from the wizard context instead of a fixed `multiview.networkSetup`; add a
  rendered test (`OpenCineHostedTestSupport` exists).
- Plan 2: reconcile Swift `SharedNetworkStore` / `SharedNetwork` with Android's `SharedNetworkStore`
  (names, `hotspot` optionality, matching test names); AppKit cannot import `OpenCineApple`, so the
  network seam carries `StationNetwork`.
- Plan 3: move the tile-note rule (no note for "Recording" / "Recording stopped") into the shared
  tile values, keyed off `RecordAll`; drop Pocket's typealias shims and the app-side `validated`
  overload; remove the unused `recordingAvailable` parameter of Pocket Android
  `multiviewTileReadouts`; unify the control-port recording gate (Pocket Android
  `MultiviewTileControl.kt` gates by availability) with iOS.
- Before merging Pocket: the on-device upgrade checklist (iPhone and Android installed over the
  current build with saved stage, networks and a pending cleanup).

## Carried from Plan 2 (2026-11-13, seam fixes 2026-11-14)

Plan 2 landed on `feat/shared-multiview-2` (OpenCine and OpenPocketCine), stacked on Plan 1. The
Plan 1 carry-overs for the locked page and `SharedNetworkStore` are done there. An independent
review's seam fixes landed on the same branches before Plan 3 builds on them: camera policy off
the commissioner (`MultiviewCameraPolicy`, with `discoversByProbe`); `open` takes an optional
expected identity and returns the proven one (the coordinator refuses a duplicate); `probe`/`open`
receive the `StationNetwork`; the repair seam carries `beginAttempt`, `bluetoothTurn`,
`waitForOperator` and a link-declared `repairDeadline` raced by `MultiviewRepairResult.race`; the
link reports `MultiviewLinkStatus` and `isPublishing` and never writes tile state. For Plan 3:

- Fakes of `StationCommissioner`, `StationHostPath` and `MultiviewMemberLink` in
  `OpenCineCoreTestSupport` and the Kotlin `core` test fixtures, written with the coordinator's
  first tests.
- Discovery through `MultiviewMemberLink.probe`, only when the policy `discoversByProbe` (Pocket
  still runs DJI's batched discovery; both DJI probes exist, take the caller's local address, and
  are not called yet).
- The coordinator takes over what Pocket's session does for the seams today: the status-to-copy
  mapping (`MultiviewSession.show`), the control host set on `controlling`, the duplicate-identity
  refusal after `open`, the race of each repair, `waitForOperator`, and a real Bluetooth queue
  behind `bluetoothTurn` (Pocket only waits for its adds and network scan; DJI's link never asks).
  `beginAttempt` maps to Pocket's DJI rejoin budget today; the coordinator maps it to
  `RecoveryBudget`.
- Whether a link's `close()` ends `isPublishing`: Pocket's session still clears `publishing` itself
  after closing a tile (keeps a foreground decoder check during a rejoin exactly as today).
- `restoreAccessPoint` returns a Bool; Luna's return distinguishes deferred from failed with
  operator copy. Decide with Plan 5 whether the cleanup prompt needs a result type.
- Swift `SharedWiFiPath` (`OpenCineApple`) and `DjiAppleSharedWiFiPath` (`OpenCineDJIApple`) are
  near copies, because `OpenCineDJIApple` may not import `OpenCineApple`. Their behavior now
  matches (the SSID read returns nil on cancellation in both). Fold the DJI one into the host path
  the commissioner already receives.
- `MultiviewAutoLUT` carries the color mode and conversion as names, because Core cannot see the
  camera vocabulary; revisit when the coordinator owns the LUT strip.
- Kotlin `DjiStationCommissioner` has no injectable retry wait (a suspend-lambda default in its
  constructor crashed the Kotlin IR backend); Pocket's test hook keeps its own retry.
- Kotlin `SharedWiFiPath.address(hotspot = this.hotspot)` became two overloads, so
  `address$default` left the ABI: source compatible, but an app on a prebuilt AAR relinks.
- Pocket Android has no unit test for the link status mapping (its `MultiviewSession` needs a
  `Context`); the coordinator's shared tests cover it on both platforms.
- The iOS/Android differences the seams keep as they are: Android's early identity read and
  Wi-Fi wake retry, foreground-only repair on iOS, probe width. Deliberate twin differences:
  `StationCameraRecord.id` (`UUID` / `String`) and restore cancellation (Swift false, Kotlin
  propagates), recorded in `docs/core/README.md`.

## Carried from Plan 3 (2026-11-14)

Plan 3 landed on `feat/shared-multiview-3` (OpenCine and OpenPocketCine), stacked on Plan 2.
AppKit's `MultiviewCoordinator` (Swift and Kotlin) owns the stage; Pocket's `MultiviewSession` on
both platforms is an adapter and its `MultiviewHost`. The Plan 1 and Plan 2 carry-overs for Plan 3
are done (tile note keyed off `RecordAll`, Pocket's typealias shims and `validated` overload gone,
Android's unused `recordingAvailable` readout parameter gone, the record port's availability gate
already matched iOS, fakes, probe discovery, the real Bluetooth queue, `RecoveryBudget`,
`isPublishing` replaced by the coordinator's `publishing` and the link's `recordReport`,
`StationRestoreResult`). For the later plans:

- Plan 4 grows `MultiviewHost` into the screen and settings popup composition: today the host
  answers Live View, editors, member changes, foreground, stage stop, whether a picture shows and
  the log; tile pictures, surfaces, the backdrop and the Live View borrow stay in Pocket.
- Plan 5: Luna's `restoreAccessPoint` returns `deferred(copy)` when the camera needs the operator
  first (the stage shows that copy after close); DJI returns only `restored` or `failed`.
- Plan 5 (N1): OpenInstaCine `ios/OpenInstaCine/AddSetupView.swift:46-56` must pass
  `complete: { done(nil) }` to the locked Shared Wi-Fi page at its next pin move.
- `DjiAppleSharedWiFiPath` stays for the single-camera transport (Multiview no longer uses it:
  the datalink takes the host path's address from its caller); fold it when that transport moves.
- `MultiviewAutoLUT` still carries names; the LUT strip is still Pocket's.
- Recovery semantics: `RecoveryBudget.beginAttempt` clears the healthy streak (DJI's own ladder
  did not), so a member that rejoins and stalls again within 30 s keeps spending its budget.
- Pocket Android keeps on purpose (handbook): 24 probes a batch, the early identity read (kept
  through a lost join reply), the decoder rebuild after Live View and repair only while a surface
  is mounted. Everything else moved to iOS's rules through the coordinator.
- Pocket Android keeps its `MultiviewMulticam` helper only for its engine tests of the record port.
- Before merging Pocket: the on-device upgrade checklist and a Multiview hardware pass on both
  platforms (add, two cameras, record together, rejoin, close cleanup), untested in this plan.

