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
- Recovery semantics (review fix): `RecoveryBudget.beginAttempt` keeps the healthy streak, as
  DJI's per-tile ladder did, so Pocket iOS keeps its frozen-picture behavior (a rejoin while the
  transport stays healthy does not restart the 30 s that restore the budget). If Luna or Nikon
  need attempts to restart the streak, add that as an explicit `RecoveryBudget` option, never as
  the default.
- Cleanup ruling (review): `StationRestoreResult` has no "give up" case. A `failed`, `deferred`,
  cancelled or thrown return keeps the camera in the journal and every later close retries it,
  as Pocket iOS does today; giving up is the operator's decision (the app's "Close anyway" leaves
  the entry journaled), never an integration result. Luna's permanent refusals (declined, held by
  another phone, unsupported) return `deferred(copy)` with the operator copy that says so; a
  "forget this camera's cleanup" action, if wanted, is a coordinator or app operation for a later
  plan.
- Seam stability (review fix): every `MultiviewRepairContext` value has a default (Swift `nil`
  defaults filled in by the initializer, Kotlin default arguments), so the context grows without
  breaking a link test. `StationVerifyFinal` (Core) lets `verifyOnNetwork` end a commissioner's
  join at once; DJI's `StationJoin` rethrows it on its lost-reply path, so the duplicate refusal is
  final there too. Kotlin's coordinator `clock` has no default: it must be the clock the links
  stamp `recordReport` on.
- Review fixes in the coordinator (both twins unless noted): the Bluetooth queue moves on when a
  LAN-only reconnect or rejoin ends and on Remove; Remove forgets the member's address (offered
  back only to the same camera), so a new camera is never opened at the removed one's address;
  repairs no longer wait while a member connects (iOS never did); an older repair task never clears
  a newer one's state; a stopped stage closes a link that opened after it; Swift's record
  confirmation returns `unconfirmed` when cancelled; Swift's host join clears only its own task;
  Kotlin `closeStage` ends (and its returns finish) for a cancelled caller; a Kotlin return that is
  cancelled or throws stays for the next close; a Kotlin keepalive, probe or scan that throws is
  logged and a repair that throws fails its member, instead of crashing the app.
- For Plan 6 (Nikon), from the review: `sightingAddress` must return a normalized dotted IPv4
  address (`StationSubnet.validAddress`; `hostKey` only normalizes comparisons); nearby discovery
  stops when the stage is full and `connectPreview` does not restart it, so a rejoin reads the last
  sighting; end Nikon's own ladder with `waitForOperator` rather than `rejoin` unless its
  per-attempt `beginAttempt` plus the coordinator's per-rejoin spend is wanted; keep `keepalive`
  non-blocking; pick a `repairDeadline` above Nikon's 30 s attempt deadline.
- Pocket Android keeps on purpose (handbook, Android differences): 24 probes a batch, the early
  identity read (kept through a lost join reply), the decoder rebuild after Live View and repair
  only while a surface is mounted. Everything else moved to iOS's rules through the coordinator,
  including the per-tile "Waiting for camera confirmation" at send and the settings editor staying
  open in the background.
- Pocket Android keeps its `MultiviewMulticam` helper only for its engine tests of the record port.
- Before merging Pocket: the on-device upgrade checklist and a Multiview hardware pass on both
  platforms (add, two cameras, record together, rejoin, close cleanup), untested in this plan.

## Carried from Plan 4 (2026-11-14)

Plan 4 landed on `feat/shared-multiview-4` (OpenCine and OpenPocketCine), stacked on Plan 3.
`MultiviewScreen` (SwiftUI in OpenCineAppKitApple, Compose in appkit) is the whole Multiview
screen and its settings popup; `MultiviewScreenHost` refines `MultiviewHost` with the app's views
(picture, settings preview and controls, Live View; SwiftUI also the backdrop and the wizard's
brand and services, Compose the wizard). Pocket renders it on both platforms. The Plan 3
carry-over for Plan 4 is done (the host answers the screen; the tile pictures, surfaces, backdrop
and Live View borrow stay Pocket's, behind the host). The coordinator fixes from the Plan 3
re-review are in (N1 a removed member's cancelled repair changes nothing, N2 a reconnect search
starts no repair on the link it closed, N3 the older-repair test). For the later plans:

- Plan 5 (OpenInstaCine) and Plan 6 (OpenZCine) adopt `MultiviewScreen` with their own host:
  pictures, settings controls (or `editsCameraSettings = false`, which hides the CAMERA tool),
  `appliesAutoLUT`, a commissioner or none (the close copy, the Add footer and the scan follow).
  The screen starts the stage itself on both platforms (`screenAppeared(startsSession:)`).
- Review fixes (capability, not brand; every default is Pocket's behavior): the wizard passes
  `cameraScansNetworks` from the commissioner (a camera that cannot scan reads "This camera can't
  list networks"); `StationCommissioner.joinsExperimentally` and `asksApprovalOnCamera` (both
  default true, as Pocket's) gate "Try experimental shared Wi-Fi", the picker's experimental row
  and "Connecting · approve on camera"; a stage without a commissioner starts on this phone's
  network (no wizard, no Shared Wi-Fi button, no host join; Compose `NetworkSetup` has an empty
  default).
- Plan 5 (OpenInstaCine): Luna's commissioner sets `joinsExperimentally = false` (no experimental
  path) and keeps `asksApprovalOnCamera` (its Bluetooth authorization); `scansNetworks` stays
  false, so the wizard says the camera cannot list networks.
- Plan 6 (OpenZCine): no commissioner, so no wizard. A stage on the phone's own hotspot needs the
  coordinator to watch the hotspot path (`usePhoneHotspot` is reset to Wi-Fi by `start()` today:
  add a host or coordinator value for it); a sighting another device holds can only be hidden or
  pickable today (`MultiviewPickerRow.enabled` exists for listing it disabled with its reason).
- The popup's categories come from `MultiviewSettingsCategory.offered`; an integration with other
  controls maps each category to its own, or adds a category to the shared enum on both twins in
  one change. Pocket maps them through an optional lookup on both platforms, so a new category does
  not break it (it shows no controls there); a host with an exhaustive `switch` or `when` adds its
  case in the same change.
- The settings editor's reopen rule is a host contract (documented on `cameraSettings`): the host
  drops its editor when the member's camera or control path changes or its link is replaced.
- `MultiviewRepairResult.race` returns `done` at once when its task is cancelled (Swift's stream
  ends; Kotlin's await throws in the cancelled job). Swift's N1 guard is pinned by
  `aRemoveQueuedBeforeTheVerdictLandsChangesNothing` (a Remove that reaches the main actor before
  the verdict; it fails without the guard). Kotlin's job check stays defensive (prompt
  cancellation already ends the repair), as does N3's guard.
- Compose has no host renderer here: the Compose screen is exercised by Pocket's
  instrumentation tests, the SwiftUI screen by the hosted `MultiviewScreenTests`.
- Before merging Pocket: a Multiview hardware pass on both platforms (the list is in the Plan 4
  report), untested in this plan.

## Carried from Plan 6 (2026-11-15)

Plan 6 is on `feat/shared-multiview-6-nikon` (OpenCine, stacked on Plan 4 with the Nikon prep #348)
and `feat/shared-multiview` (OpenZCine). The Plan 4 re-review N1 (no unnamed network saved) and N2
(`MultiviewNetworkPath`, a stage on the phone's own hotspot) are done in AppKit on both twins.
OpenZCine runs the shared coordinator and screen on iOS and Android through its own host, over
`NikonMultiviewLink`. For later:

- Hardware: the Nikon pass on iOS and Android (the list is in the Plan 6 report) gates merging.
  The 1200 ms settle, the 5 s reopen spacing and the 45 s repair deadline are untested on bodies.
- Bodies another device holds are hidden from the Add list (Pocket lists only addable cameras).
  `NikonMultiviewCamera` keeps the holder, so a disabled row with "In use on ..." is a small shared
  change (`MultiviewPickerRow.enabled` from a policy reason) if the hardware pass wants it.
- USB-C and camera access-point members left Multiview (the stage opens members at a network
  address). A non-network member path would be a coordinator change.
- Pairing a body happens in OpenZCine's camera list; Multiview opens paired bodies only and shows
  no pairing code.
- The Nikon link's common session is per opened link (`NikonCameraSession` fixes the serial at
  init); the `MultiviewMemberLink.session` doc says "one for the member's lifetime". Either relax
  the doc or let `NikonCameraSession` rebind its driver.
- The OpenZCine journal is a no-op: `MultiviewStageJournal.Stage.validated` drops a stage without
  a network name, so a no-commissioner stage keeps its layout through `presentation` only.
- Plan 5 and Plan 6 both touched AppKit from the same base; the coordinator reconciles them.

Plan 6 review fixes (2026-11-15), carried to Plan 5 (#357) as shared AppKit and Core commits:
`MultiviewLinkRefusal` (Core) puts a link's refusal copy on the tile instead of "not found";
Reconnect without a commissioner keeps the proven identity (no re-add with none); the host's
`pickerGuidance` adds setup steps under the Add list footer. Nikon-only: a restart counts only on
a new frame (replays ignored), a dead link reopens at once (two reopens per budget), a lent
session lost in Live View closes through the opener, the scanner does not report held bodies,
`notPaired` copy, `awaitClosed()` for the app's settle after a stage closes. Still for later:

- The network confirmation step the spec's Nikon column names ("confirms the phone's network")
  is not built: without a commissioner there are no credentials to hand a camera, and `.either`
  follows the network the phone is on. An owner call; a confirm-only wizard page would be a
  shared screen change on both twins.
- No video backdrop and a still settings preview on OpenZCine: a Z body's live view is PTP JPEG
  stills, so there is no decoder sample bus for `monitorVideoBackdrop` or the assist inspector.
- A Z body reports no take length: OpenZCine's tally reads REC without a time (Pocket shows the
  camera's own), never a phone-derived count.
- Kotlin `NikonMultiviewLink.closeLimit` bounds the wait for an earlier close (10 s), so a close
  slower than that lets the next Init start before the opener records it. Whether a ZR's
  CloseSession ever takes that long is a hardware question.
