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

## Carried from Plan 2 (2026-11-13)

Plan 2 landed on `feat/shared-multiview-2` (OpenCine and OpenPocketCine), stacked on Plan 1. The
Plan 1 carry-overs for the locked page and `SharedNetworkStore` are done there. For Plan 3:

- Fakes of `StationCommissioner`, `StationHostPath` and `MultiviewMemberLink` in
  `OpenCineCoreTestSupport` and the Kotlin `core` test fixtures, written with the coordinator's
  first tests.
- Discovery through `MultiviewMemberLink.probe` (Pocket still runs DJI's batched discovery; both
  DJI probes exist but are not called yet).
- Swift `SharedWiFiPath` (`OpenCineApple`) and `DjiAppleSharedWiFiPath` (`OpenCineDJIApple`) are
  near copies, because `OpenCineDJIApple` may not import `OpenCineApple`. Fold the DJI one into
  the host path the commissioner already receives.
- `MultiviewAutoLUT` carries the color mode and conversion as names, because Core cannot see the
  camera vocabulary; revisit when the coordinator owns the LUT strip.
- Kotlin `DjiStationCommissioner` has no injectable retry wait (a suspend-lambda default in its
  constructor crashed the Kotlin IR backend); Pocket's test hook keeps its own retry.
- The iOS/Android differences the seams keep as they are: Android's early identity read and
  Wi-Fi wake retry, foreground-only repair on iOS, probe width.
