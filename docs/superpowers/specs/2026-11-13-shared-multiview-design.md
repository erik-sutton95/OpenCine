# Shared Multiview: one Pocket-standard Multiview for every app

Date: 2026-11-13. Owner direction: "OpenPocketCine is our gold standard for multi-cam. We should
get ZCine and InstaCine to be identical." Calls marked "(call)" are the agent's, open to the
owner's correction.

## Intent

Today three apps have three multicam features. OpenPocketCine's Multiview (DJI) is the most
complete and is hardware-proven (Pocket 3, Pocket 4 Pro and Nano together on one iPhone).
OpenZCine (Nikon) has a simpler stage of its own. OpenInstaCine (Insta360 Luna) got a Z-style
stage on 2026-11-12 (branch `feat/multicam`, unpublished). The operator should find the same
Multiview in every app: the same entry, wizard, add flow, tiles, record behavior, tools, settings
popup, Live View hand-off, LUT, recovery and close.

The way to make three apps identical and keep them so is to have one implementation: lift
Pocket's Multiview into OpenCine's app shell and let each app supply only what its camera
integration really differs in. This follows AGENTS.md ("shared behavior goes here",
capability not brand).

## Goals

- One Multiview coordinator, screen composition and settings popup in OpenCine (`OpenCineAppKit`
  / Android `:appkit`, engine pieces in `OpenCineMulticam` / `:multicam`), Swift and Kotlin in step.
- OpenPocketCine moves onto it first with no operator-visible change on iOS, and Pocket Android
  moves to the iOS behavior (its UI tests and the handbook page `guides/multiview-prototype.md`
  are the acceptance reference).
- OpenZCine and OpenInstaCine then adopt it and match Pocket everywhere their cameras allow.
- Where a camera cannot do what Pocket does, the difference comes from a declared capability,
  never a brand branch, and the copy says what to do instead.

## Non-goals

- New Multiview features beyond Pocket's current behavior.
- Synchronized (frame-accurate) recording, genlock or shared clock.
- Restoring a saved stage's cameras: Pocket does not (it keeps layout, selection, Fit/Fill and
  the cleanup record only), so neither will the others.
- Reverse-engineering Nikon SnapBridge Bluetooth to move a Z body onto a network (separate
  research, see "Open for the owner").

## Anti-goals (failure even if it works)

- A copy of Pocket's code pasted into two more apps.
- Any regression in Pocket's hardware-proven Multiview.
- A shared layer that branches on manufacturer or app.
- Silently pretending a camera did something it cannot (for example showing "returning cameras
  to their Wi-Fi" for a Nikon).

## The reference behavior

Pocket's handbook page `OpenPocketCine/handbook/src/content/docs/guides/multiview-prototype.md`
is the operator-facing spec. Where Pocket iOS and Pocket Android differ today (toolbar order,
tally text, format line, tile status text and actions, settings categories and when editing is
allowed, Bluetooth discovery demand, probe width, recovery details, storage), the shared
implementation takes the iOS behavior (owner, 2026-11-13), except where the
handbook names an Android difference on purpose (for example 24 parallel probes).

## Architecture

### Already shared (keep)

`MultiviewStage` and its values (`MultiviewTile`, `MultiviewTally`, `MultiviewRecordContext`,
`MultiviewStageState`, `MultiviewStagePreferencesStore`, `MultiviewCameraPicker`,
`MultiviewNetworkRestore`), the station wizard (`StationNetworkSetup` with its `.multiview`
context), `StationJoin`, `StationRoutes`, the multicam engine (`RecordPlan`, `ResourceAdmission`,
`EditorLeases`, `RecoveryBudget`), the Auto LUT lookup, `ShellModel.borrow`.

### Lifted from Pocket into OpenCine

- `MultiviewCoordinator` (AppKit, both platforms): lifecycle, network choice, Bluetooth
  discovery demand, add (one at a time per Bluetooth, concurrent setup as Pocket), LAN discovery
  loop (cached address first, two passes, other tiles excluded, address reserved per tile),
  identity check, shared record lamp and per-tile record (strict plan, 3 s status freshness, 8 s
  confirmation window, record confirmation preference), recovery budget (bounded rejoin, 45 s
  path loss), Live View hand-off ordering, settings editor leases, close and cleanup, background
  and foreground, Reconnect and Remove.
- `MultiviewStageJournal` (AppKit, Codable): stage, cameras, validation, cleanup targets. Storage
  is a load/save pair; Pocket's existing Keychain and SharedPreferences names and JSON keys stay
  so saved stages from older builds decode.
- Swift `RecordAll` in `OpenCineMulticam` (Kotlin has it).
- Swift `SharedNetworkStore` in `OpenCineApple` matching Android's, same Keychain names as
  Pocket's `MultiviewNetworkStore`.
- Tile value mapping (readouts, tally, format line) and settings categories as pure functions.
- Screen and settings popup composition behind a `MultiviewHost` seam.
- `StationNetworkSetupView` gains `lockedNetwork` on iOS (Android has it).

### Seams each app or integration supplies

Names and rough shapes; exact signatures are the builder's, kept consistent with OpenCine style
(Core `CameraSession`, `MulticamQualification`, ports, host values).

- `StationCommissioner` (integration, optional): qualification and preview support for a nearby
  camera; commission it onto a `StationNetwork` with an identity proof; restore its own access
  point (retryable); optional network scan through a camera. DJI: today's provisioner. Luna: the
  station move over Bluetooth (`LunaStationJoin`), plus new integration work below. Nikon: none.
- `StationHostPath` (platform): the phone side of the shared network (address, netmask, join).
  iOS `DjiAppleSharedWiFiPath` generalised; Android `SharedWiFiPath` (with the owner counting
  added on `feat/insta360-multicam`).
- `MultiviewMemberLink` (integration): one tile's link: Core `CameraSession`, picture health,
  probe, open at an address with identity check, preview start, keepalive, close, the
  integration's own repair step, Auto LUT source (color mode plus look profile).
- `MultiviewHost` (app): record confirmation preference, Live View borrow, settings editor, the
  tile picture view.

### Per camera: what "identical" means

| Pocket feature | DJI (Pocket) | Luna (InstaCine) | Nikon (ZCine) |
|---|---|---|---|
| Wizard: Wi-Fi or Hotspot, saved password | as today | same | same (confirms the phone's network) |
| Add a nearby camera over Bluetooth, app moves it onto the network | as today | same, through the Luna commissioner | **cannot**: Z bodies have no app-side network move. Add lists bodies found on the current network by active discovery (members excluded) plus saved router/hotspot setups, with the camera-menu steps and the on-camera pairing code |
| LAN discovery, identity checked, members excluded | as today | done on `feat/insta360-multicam` (serial) | `NikonDiscovery` `.active` with `excludedHosts`; serial from GetDeviceInfo |
| Per-tile picture, own link, bounded automatic recovery | as today | member session recovery, put under the coordinator's budget and Bluetooth queue; LAN-first reconnect (new) | automatic ladder over `NikonSessionRecovery` / `LiveViewWatchdog` within the coordinator budget, respecting the ZR reconnect settle |
| Shared record lamp, per-tile record | strict | strict | strict (today eligible subset; changes) |
| Layout, Fit/Fill, toolbar, saved presentation | as today | same | same |
| Settings popup with camera tabs | as today | same (ISO, shutter, WB, focus over `LunaCameraSession`) | same (existing `MulticamCameraSettings` behind the shared popup) |
| Double-tap tile to Live View and back | as today | borrow the member's session and decoder into the monitor (Pocket pattern) | existing lend/reclaim behind the shared hand-off |
| Tile readouts | as today | camera model (not the route label); timecode is phone-derived and labelled so | camera model; timecode HH:MM:SS like Pocket |
| Auto LUT per camera, on by default | as today | follows the preview color mode (Color Recovery makes the feed Rec.709 unless turned off) | on by default from N-Log / Log3G10 tone (Z today is deliberately off; changes) |
| Close returns cameras to their own Wi-Fi | as today | new standalone "authorize, switch to access point, disconnect" plus cleanup record | **cannot**: "Recording continues" close, no return step |
| Saved stages | layout and cleanup record | same | layout only (no cleanup needed) |

### New integration work

- Luna: standalone return-to-access-point operation (Swift and Kotlin), LAN-first reconnect to
  the known host with serial check before falling back to Bluetooth, and a first-class "nearby
  camera onto this station network" connect target.
- Nikon: Multiview discovery through `NikonDiscovery` `.active` with `excludedHosts`; tone
  property polling for Auto LUT. A second Init from another device drops the first session, so
  discovery must never Init a host that a member holds.
- Everything on `feat/insta360-multicam` (serial-checked station search, `stationHostsInUse`,
  `SharedWiFiPath` owners, `LunaMulticamPolicy`) is kept.

## Order of work

Each step leaves every app working; Pocket's Multiview tests and a Pocket hardware pass gate the
lift.

1. Prep in OpenCine and Pocket, no behavior change: delete Pocket's dead
   `MultiviewWiFiControl.swift`; Swift `RecordAll`; move Pocket iOS's provisioner into
   `OpenCineDJIApple` (Android already has it in `:dji`); Swift `SharedNetworkStore`; iOS
   `lockedNetwork`.
2. Pure values into AppKit (journal, tile values, settings categories) with their tests ported;
   settle the iOS/Android differences here.
3. Seams defined; DJI implementations wrap today's Pocket tile and provisioner internals.
4. `MultiviewCoordinator` lifted; Pocket's `MultiviewSession` becomes a thin adapter. Parity
   tests first; Pocket UI tests each step.
5. Screen and settings popup composition lifted behind `MultiviewHost`.
6. OpenInstaCine adopts (Luna commissioner and member link, Live View borrow, settings, Auto LUT,
   return to access point). Replaces the Z-style stage on `feat/multicam`.
7. OpenZCine adopts (Nikon member link, discovery-based add, automatic recovery, strict record,
   Auto LUT on, no-return close).
8. Handbooks: each app's Multiview page mirrors Pocket's, with its capability notes.

Each step is its own reviewed OpenCine PR followed by app pin moves, per AGENTS.md "add, migrate,
remove". Nothing is pushed or merged without the owner.

## Verification

- Shared tests on both platforms against fake commissioner and member links (ported from Pocket's
  persistence, engine, stage and readout tests); DJI-specific tests move to `OpenCineDJI` / `:dji`;
  app UI tests stay in the apps.
- Pocket: its full Multiview UI and unit suites after every step, and a hardware pass (three
  cameras, record, settings, Live View, close) before the lift is called done.
- Luna and Nikon: hardware passes on iOS and Android, published as live checklists. Until then
  every claim stays "untested".

## Left to the builder

Exact type and method names, file layout inside AppKit, how Compose and SwiftUI composition is
split behind `MultiviewHost`, the test harness for fakes, and the PR slicing within each step.

## Settled calls (agent's, after a builder review)

- Starting point: OpenCine `feat/insta360-multicam` (serial-checked Luna station search,
  `stationHostsInUse`, `SharedWiFiPath` owners, `LunaMulticamPolicy`) goes to main first as its
  own fix PR; it fixes a real Android wrong-camera case regardless of Multiview. OpenInstaCine's
  Z-style stage on `feat/multicam` is not shipped; its Luna member code is reused in step 6 and
  the branch is then retired (call).
- Nikon discovery never sends an Init to a host it has not been asked to open: Add lists bodies
  from passive discovery and saved setups, and only the body the operator picks is opened and
  identity-checked. A host held by a member, or by ZCine's own Live View, is never probed (call).
  Swift `NikonDiscovery` gains `excludedHosts` to match.
- The DJI member link may be supplied by the app through `MultiviewHost` (wrapping Pocket's own
  `CameraSession` tiles); moving Pocket's session code into `OpenCineDJIApple` is not a
  prerequisite. The seam is "integration or app supplied" (call).

## Owner answers (2026-11-13)

1. Pocket iOS behavior wins everywhere: one identical Multiview on every app and platform.
   Pocket Android changes to match iOS and the handbook, and gets its own hardware pass. The
   "no operator-visible change" rule in the goals applies to Pocket iOS; Pocket Android changes
   only toward iOS.
2. The Luna and Nikon adoptions wait for a hardware pass on the owner's cameras (iOS and
   Android, live checklist) before merging.
