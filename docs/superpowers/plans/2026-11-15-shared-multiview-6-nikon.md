# Shared Multiview Plan 6: OpenZCine adopts the Pocket-standard Multiview

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Nikon Z bodies join the shared Multiview (spec steps 7 and 8 for Nikon): the Nikon
integration supplies the camera policy, the Add list's passive sightings and a member link over
the Plan 6 prep operations (#348), and OpenZCine on iOS and Android replaces its own multicam stage
with the shared `MultiviewCoordinator` and `MultiviewScreen` through an app `MultiviewScreenHost`.
The operator meets Pocket's Multiview, with Nikon's capability differences only (no commissioner,
no network wizard, no return-to-Wi-Fi close).

**Architecture:** Three layers.

1. AppKit (shared, both twins, small and capability-shaped): a no-commissioner add saves no
   unnamed network (Plan 4 re-review N1), and a new `MultiviewNetworkPath` coordinator value lets
   a stage without a commissioner watch whichever of the phone's networks it is on, its Wi-Fi or
   its own hotspot (re-review N2). Defaults keep every Pocket path.
2. Nikon integration (Swift `OpenCineNikon`, Kotlin `:nikon`, twins with the same names):
   `NikonMultiviewCamera` (a sighting or saved setup, no serial), `NikonMultiview.policy`
   (`discoversByProbe = false`, Nikon host keys, held bodies refused), `NikonMultiviewScanner`
   (the Add list over `multiviewSightings` plus saved router and hotspot setups, member hosts
   excluded), and `NikonMultiviewLink`, the `MultiviewMemberLink` over `NikonMemberOpener`
   (identity-checked open and reopen, the 1200 ms settle), the member pump (frames, queued writes
   and record at the safe point, the 5 s property and tone poll), `NikonMemberRepair` mapped to the
   repair context, `NikonRecordingTone` for Auto LUT, and the Live View loan.
3. OpenZCine: a `MultiviewScreenHost` per platform (tile picture with Auto LUT, settings controls
   over the member's borrowed editor, Live View through the existing loan and hand-off with the
   single-camera monitor, record confirmation preference), the shared screen in place of
   `MulticamStage`, the old multicam coordinator and its tests removed, a handbook page.

**Tech Stack:** Swift 6 (SwiftPM, Swift Testing, Observation, SwiftUI), Kotlin 2.4 (JVM 17,
explicit API, Compose), XCTest in OpenZCine iOS, JUnit in OpenZCine Android.

**Spec:** `docs/superpowers/specs/2026-11-13-shared-multiview-design.md` ("Per camera", steps 7
and 8, "Settled calls" on Nikon discovery, "Owner answers"); series:
`docs/superpowers/plans/2026-11-13-shared-multiview-roadmap.md` (every "Carried from Plan N" item
for Plan 6); prep `docs/superpowers/plans/2026-11-13-nikon-multiview-prep.md` and its re-review
(N1 to N6); Plan 4 re-review N1 and N2; `docs/nikon/README.md` "Multiview prep"; Pocket handbook
`guides/multiview-prototype.md` (the reference).

## Global Constraints

- OpenCine `AGENTS.md`: twins with the same type and test names; capability, not brand (no
  manufacturer or app name in AppKit, `SharedUIRulesTests`); no em dash character (Kotlin strings
  write `\u2014`); Conventional Commits, no co-author trailers, explicit `git add`; behavior tests at
  contract boundaries on manual clocks and gates, no sleeps.
- Nikon protocol rules (hard): discovery never sends a PTP-IP Init to a host it was not asked to
  open, nor to a host a member or ZCine's own Live View holds; the Add list is passive
  (`multiviewSightings`); only the body the operator picks is opened and identity-checked (serial
  from GetDeviceInfo after OpenSession); every close or failed dial starts the host's 1200 ms
  settle; Nikon passive discovery and the per-operation admission rules are not changed. No
  commissioner: the app never moves a body onto a network or back; close returns nothing.
- Shared AppKit and Core changes stay minimal, additive, defaulted to Pocket's behavior, in their
  own commits (a parallel Plan 5 stream builds on the same base).
- Public API changes update snapshots in the branch (`atlas api --write --build`,
  `./gradlew updateKotlinAbi updateAndroidApi`). JNI: no `NikonNative` member changes.
- OpenZCine: both shells in one deliverable; `opencine-pins.txt` is not moved (the app builds
  against the sibling `../OpenCine`); hardware behavior is reported untested.
- Scratch only under `/Volumes/OCScratch/smv6/`; iOS tests on the private simulator `opc-smv6`,
  deleted at the end; never `./gradlew --stop`.

## Review Focus

- Nikon rules: no Init from the Add list, no Init to a member's host, settle honored on every
  close and failed dial, a late link from a timed-out reopen is closed (prep re-review N1), a
  reopen's `hostInUse` is "still dialling", not a failure to show (N2).
- The repair mapping: one budget spend per automatic attempt (the ladder asks `beginAttempt`; the
  link never returns `.rejoin`, so the coordinator never spends a second time), `repairDeadline`
  above the ladder's 30 s attempt deadline, and frames from a replaced transport are ignored.
- Pocket unchanged: `MultiviewNetworkPath` defaults to `.chosen` (today's behavior) and the saved
  network guard only skips an empty SSID, which no commissioner path produces.
- OpenZCine: the Live View hand-off between a member and the single-camera monitor (one mount of
  the shell), strict record, Auto LUT on by default, and what an existing user keeps.

## Rulings taken while planning (recorded again in the report)

1. USB-C members leave Multiview. The shared stage opens members at a network address on the
   phone's network (`StationSubnet.validAddress`); the spec's Nikon column lists network bodies
   only. ZCine's old stage mixed USB-C with router and hotspot paths. Cost if wrong: a later plan
   adds a non-network member path to the coordinator.
2. Bodies another device holds are not listed (Pocket lists only addable cameras): the policy
   refuses them `.notReachable`, so the shared picker hides them; `NikonMultiviewCamera.heldBy`
   keeps the holder for a later disabled row (`MultiviewPickerRow.enabled`). A member taken over
   during a repair waits for the operator with copy naming the holder; Multiview never offers a
   take-over.
3. The member's common session is per opened link: `NikonCameraSession` fixes the body serial at
   init, so each open or reopen makes a new control (the coordinator reads `link.session` every
   time; a record confirmation or editor lease made before a replacement goes stale, as ZCine's
   old stage did).
4. The link never returns `.rejoin`: the Nikon ladder pays each automatic attempt through
   `beginAttempt` and ends in `waitForOperator` (roadmap Plan 3 note). `repairDeadline` is 45 s.
5. Saved data: the stage layout, selection and Fit/Fill stay under ZCine's existing preference
   key (`multiview.presentation`, both platforms), attached to the coordinator's presentation as
   today. Nothing else from the old stage is stored (it kept no camera list); the saved camera
   setups the Add list merges in are the app's existing saved records, read only. The shared
   journal is not written on ZCine: a no-commissioner stage has no network name, so the journal's
   own validation would drop it, and Nikon needs no cleanup record (spec: "layout only").
6. Per-member look choice (ZCine's LUT panel with any stored cube) is replaced by Pocket's Auto
   LUT: on by default, following the recording tone (N-Log to the N-Log look, Log3G10 to the
   Log3G10 look, SDR and HLG need none).
7. Strict record replaces ZCine's eligible-subset start (spec "Per camera").

---

### Task 1: AppKit, no unnamed network saved (Plan 4 re-review N1)

**Files:** `Sources/OpenCineAppKit/MultiviewCoordinator.swift`,
`Android/appkit/src/main/kotlin/com/opencapture/opencine/appkit/MultiviewCoordinator.kt`, their
tests `Tests/OpenCineAppKitTests/MultiviewCoordinatorTests.swift`,
`Android/appkit/src/test/.../MultiviewCoordinatorTest.kt`.

- [ ] Extend `withoutACommissionerTheStageUsesThePhonesNetworkWithoutTheWizard` (both twins) with
  "no network is saved" (`savedNetworks.isEmpty`); run, see it fail.
- [ ] Guard both no-commissioner and commissioner saves in `add` with a non-empty SSID (one
  private `saveNetwork()`), both twins; run, pass. Commit `fix(appkit): ...`.

### Task 2: AppKit, `MultiviewNetworkPath` (Plan 4 re-review N2)

**Interfaces:**

```swift
/// Which of this phone's networks a Multiview stage watches. Kotlin twin: `MultiviewNetworkPath`.
public enum MultiviewNetworkPath: Hashable, Sendable {
    /// The network the stage chose: this phone's hotspot when the hotspot source is picked, else
    /// its Wi-Fi. A stage without a commissioner watches Wi-Fi. The default.
    case chosen
    /// Whichever network this phone is on: its Wi-Fi when it has an address there, else the
    /// hotspot it hosts. For a stage without a commissioner whose cameras may share the phone's
    /// own hotspot.
    case either
}
// MultiviewCoordinator.init(..., networkPath: MultiviewNetworkPath = .chosen, clock:)
```

Kotlin: `enum class MultiviewNetworkPath { CHOSEN, EITHER }`, constructor parameter
`networkPath: MultiviewNetworkPath = MultiviewNetworkPath.CHOSEN` added last.

- [ ] Tests first, both twins: `aStageOnThePhonesHotspotWatchesTheHotspot` (no commissioner,
  `.either`, the phone has only a hotspot address: the stage is ready, a sighted camera goes live
  and stays without "Shared network lost" past 45 s) and
  `aProbingStageOnThePhonesHotspotSearchesTheHotspotSubnet` (probe discovery, hotspot only: the
  camera without a sighting is found on the hotspot subnet instead of "unsupported subnet").
  Run, see both fail to compile, then fail.
- [ ] Implement: one private `pathAddress()` / `pathNetmask()` pair used by `tick`, the repair
  context, `monitorPreview` and `probeCandidates`; under `.either` the tick follows the path into
  `usePhoneHotspot` (journal and `stationNetwork` read it). Run, pass, plus the whole coordinator
  suite. Commit `feat(appkit): ...`.

### Task 3: Nikon Swift, policy, camera, scanner and member link

**Files:** create `Sources/OpenCineNikon/NikonMultiviewLink.swift`,
`Sources/OpenCineNikon/NikonMultiviewSightings.swift`; modify `NikonMultiview.swift` (copy only if
needed); tests `Tests/OpenCineNikonTests/NikonMultiviewLinkTests.swift`.

**Interfaces (Kotlin twins in `:nikon`, same names):**

```swift
public struct NikonMultiviewCamera: Hashable, Sendable {
    public var host: String          // normalized dotted IPv4
    public var name: String
    public var heldBy: String?       // another device holds it now
    public var id: UUID              // stable per host key
    public var record: StationCameraRecord
}
public struct NikonMultiviewSavedSetup: Hashable, Sendable { host, name }
public enum NikonMultiview {
    public static let policy: MultiviewCameraPolicy<NikonMultiviewCamera>
    public static func addList(sightings: [DiscoveredCamera], saved: [NikonMultiviewSavedSetup]) -> [NikonMultiviewCamera]
}
public final class NikonMultiviewScanner: NearbyCameraScanner { Camera = NikonMultiviewCamera }
public protocol NikonMultiviewTransport: NikonControlTransport {
    var serialNumber: String { get }
    func configureMemberLiveView() async
    func startLiveView() async throws
    func stopLiveView() async
    func liveViewFrame(deadline: Duration?) async throws -> PTPLiveViewFrame
    func readStorageInfo() async throws -> PTPStorageInfo?
    func shutdown() async
}
@MainActor public final class NikonMultiviewLink<Transport: NikonMultiviewTransport>: MultiviewMemberLink {
    public init(opener:, conversion:, whiteBalancePresets:, isCameraRefusal:, clock:, ...)
    public var onFrame: (@MainActor (PTPLiveViewFrame) -> Void)?
    public var control: NikonMemberControl? { get }   // the app's editor borrows its session
    public var reported: PTPCameraPropertySnapshot { get }
    public var storage: PTPStorageInfo? { get }
    public var recordingTone: NikonMovieTone? { get }
    public func lend() -> Transport?                   // Live View borrows the open session
    public func reclaim(_ transport: Transport?)       // same, replacement or nil (lost)
}
public enum NikonMultiviewLinkError: LocalizedError  // operator copy per refusal
```

`NativeCameraSession` conforms to `NikonMultiviewTransport` in OpenCineNikon (Darwin).

- [ ] Tests first (scripted transport and network, manual clock; behaviors, not calls):
  the Add list merges sightings and saved setups by host key, never lists USB, access-point or
  excluded hosts, refuses held bodies; the scanner reports passes until stopped and never asks a
  member's host; `open` checks the identity and maps refusals to operator copy without dialling a
  held body; the pump publishes frames, record reports and the tone's Auto LUT, and sends queued
  writes and record only at its safe point; three missed frames restart live view in place, a
  failed restart reopens the same body after the settle, a budget refusal or take-over waits for
  the operator, a reopen link that arrives after the repair was cancelled is closed; `close` ends
  the session without a record command and the next open waits for it; the loan stops the pump
  and a replacement from Live View is a new control.
- [ ] Implement until green. Commit `feat(nikon): ...`.

### Task 4: Nikon Kotlin twin

Same types and test names in `Android/nikon` (`NikonMultiviewLink.kt`,
`NikonMultiviewSightings.kt`, `NikonMultiviewLinkTest.kt`), over the Kotlin `NikonMemberOpener`,
`NikonMemberRepair`, `CameraPropertySnapshot.recordingTone` and the nikon `CameraSession` (frames
arrive as its `liveFrames` flow; the link watches the frame deadline). `:nikon:test`,
`:nikon:lint`. Commit `feat(nikon): ...`.

### Task 5: OpenCine docs and API snapshots

- [ ] `docs/nikon/README.md` "Multiview" (what the link does, rulings 1 to 4),
  `docs/multicam/README.md` Nikon bullet, appkit README capability table (`networkPath`), roadmap
  "Carried from Plan 6". Commit `docs: ...`.
- [ ] Snapshots: `atlas api --write --build`, `./gradlew updateKotlinAbi updateAndroidApi`.
  Commit `chore: API snapshots ...`.

### Task 6: OpenZCine iOS on the shared screen

**Files:** create `ios/Runner/ZCineMultiviewHost.swift`; modify `NativeAppRoot.swift`,
`LinkExperience.swift`, `DemoHarness.swift`, `MulticamPicture.swift` (picture only),
`MulticamCameraSettings.swift` (editor only), `MulticamLinks.swift` (demo transport); delete
`MulticamCoordinator.swift`, `MulticamStage.swift`; tests: replace `MulticamCoordinatorTests.swift`
with `ZCineMultiviewHostTests.swift`, keep the picture fencing tests.

- [ ] Tests first: the host's tile readings (name, format, storage, timecode HH:MM:SS, battery),
  Auto LUT follows the tone and the member's choice, Live View loan returns the member to its
  tile, the record confirmation preference, the stage layout keeps the existing key.
- [ ] Implement; demo stage (`ZC_DEMO_MULTICAM`) on scripted transports; `just native-check`
  scope on the private simulator; screenshots of the demo stage in landscape.
- [ ] Commit `feat(multiview): ...`.

### Task 7: OpenZCine Android on the shared screen

Same on Android (`multicam/` replaced by `multiview/ZCineMultiviewHost.kt` and its Compose host),
unit tests, lint, androidTest compile (`-x stageSwiftCore`). Commit `feat(multiview): ...`.

### Task 8: OpenZCine handbook page

`handbook/src/content/docs/guides/multiview.md` mirroring Pocket's page with the Nikon capability
notes; every hardware behavior marked untested. Commit `docs(handbook): ...`.

### Task 9: Verification, push, draft PRs, report

Gates per the brief; push both branches; draft PRs (OpenCine base `feat/shared-multiview-4`,
OpenZCine base `main`); the report with the Nikon hardware pass list for iOS and Android.
