# Nikon Multiview Prep (Shared Multiview roadmap Plan 6, integration part) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Nikon integration the four operations a Pocket-standard Multiview needs from it (a picker listing that never disturbs another connection, an identity-checked open of the picked body, the member's recording tone for Auto LUT, and a bounded repair step) on Swift and Kotlin with the same names, unit-tested against scripted links, before OpenZCine adopts the shared Multiview.

**Architecture:** Integration code only (`OpenCineNikon`, Android `:nikon`). Everything new is a plain value or a small class over closures, so Plan 6 can wrap it in the AppKit seams that the parallel Plan 2 stream defines (`StationCommissioner`, `StationHostPath`, `MultiviewMemberLink`) without this branch naming them. `NikonDiscovery` gains `multiviewSightings` (a passive pass: no control-port dial, no PTP byte, excluded hosts not dialled and not listed) and compares excluded hosts by their normalized key in the active search. `NikonMemberOpener` opens one picked host, reads the body serial, refuses (closing cleanly) a host in use, a body already in the group, a different body than expected or a body with no serial, and keeps the ZR reconnect settle (1200 ms) between a close and the next Init to the same host. `NikonRecordingTone` (Swift) and `CameraPropertySnapshot.recordingTone` (Kotlin) expose the member's recording tone and its neutral `MonitorTransfer`; Swift `NikonMemberControl.pollRecordingTone(on:)` is the member poll's two-read step (Android's Swift session already polls the tone properties in its live-monitor round robin). `NikonMemberRepair` is a pure ladder (restart live view in place, then reopen after the settle, spaced) that asks the caller's budget before every attempt.

**Tech Stack:** Swift 6 (Swift Testing), Kotlin (kotlin.test, kotlinx-coroutines-test), SwiftPM, Gradle.

**Spec:** `docs/superpowers/specs/2026-11-13-shared-multiview-design.md` (branch `feat/shared-multiview-1`): "New integration work: Nikon", the Nikon column of "Per camera", settled call on Nikon discovery. Roadmap: `docs/superpowers/plans/2026-11-13-shared-multiview-roadmap.md`, Plan 6.

**Depends on:** nothing unmerged. Plan 6 (OpenZCine adoption) consumes it after Plans 2 to 4.

## Global Constraints

- Never the em dash character (Kotlin strings write `\u2014`).
- Conventional Commits as `Erik Sutton <9084979+erik-sutton95@users.noreply.github.com>`, no co-author or Claude trailers, `git add <path>` explicitly.
- Edit only `Sources/OpenCineNikon`, `Tests/OpenCineNikonTests`, `Android/nikon`, docs and API snapshots. No app, no AppKit Multiview seam, no JNI export change, no new dependency or target edge.
- Swift and Kotlin twins keep the same type, member and test names.
- Existing `.passive` and `.active` behavior of `discover` / `search` is unchanged except the excluded-host comparison (AGENTS.md: Nikon passive discovery changes only with a hardware-qualified reason; the new picker pass is additive).
- Tests: deterministic, manual clocks, scripted links, no sleeps. Hardware behavior is reported untested.
- Build scratch under `/Volumes/OCScratch/nikon/`.

## Review Focus

1. **No Init to a host that was not picked, or that a member or Live View holds.** `multiviewSightings` runs over the passive dialer; `NikonMemberOpener.open` refuses `hostsInUse` before it dials. Tests: `multiviewSightingsNeverDialsTheControlPortOrAnExcludedHost`, `openRefusesAHostInUseWithoutDialling`.
2. **A picked body already on the stage is closed, not kept.** Test: `openClosesAndRefusesABodyAlreadyInTheGroup`.
3. **Settle before re-Init.** Test: `openWaitsTheReconnectSettleAfterAClose`.
4. **Unknown tone is nil, never SDR.** Tests: `recordingToneIsUnknownUntilTheCodecReads`, Kotlin `recordingToneIsUnknownForAnUnnamedTone`.
5. **Repair never exceeds the caller's budget and never re-Inits early.** Tests: `repairAsksTheBudgetBeforeEveryAttempt`, `repairReopensOnlyAfterTheSettle`.

## File Structure

| Path | Responsibility |
|---|---|
| `Sources/OpenCineNikon/NikonDiscovery.swift` | normalized excluded hosts; `multiviewSightings` |
| `Sources/OpenCineNikon/NikonMultiview.swift` (new) | `NikonMemberTiming`, `NikonMemberOpener`, `NikonMemberOpenResult`, `NikonMemberOpenRefusal`, `NikonRecordingTone`, `NikonMemberRepair` |
| `Sources/OpenCineNikon/NikonMovieTone.swift` | `NikonMovieTone.monitorTransfer` |
| `Sources/OpenCineNikon/NikonMulticam.swift` | `NikonMemberControl.recordingTone`, `pollRecordingTone(on:)` |
| `Tests/OpenCineNikonTests/NikonDiscoveryTests.swift`, `NikonMultiviewTests.swift` (new) | Swift tests |
| `Android/nikon/src/main/kotlin/com/opencapture/opencine/nikon/NikonDiscovery.kt` | Kotlin twin of the discovery changes |
| `Android/nikon/src/main/kotlin/com/opencapture/opencine/nikon/NikonMultiview.kt` (new) | Kotlin twins, `NikonMovieTone`, `CameraPropertySnapshot.recordingTone` |
| `Android/nikon/src/test/kotlin/com/opencapture/opencine/nikon/NikonDiscoveryTest.kt`, `NikonMultiviewTest.kt` (new) | Kotlin tests |
| `docs/nikon/README.md`, `docs/multicam/README.md` | docs |
| `atlas/api/swift/OpenCineNikon*`, `Android/nikon/api/nikon.api` | API snapshots |

---

### Task 1: Discovery that never disturbs other connections

**Interfaces (Swift; Kotlin same names):**

```swift
extension NikonDiscovery {
    public func multiviewSightings(savedHosts: [String], excludedHosts: Set<String>, browsesUSB: Bool = true) async -> [DiscoveredCamera]
}
```

Rows reuse the existing twins (Swift `DiscoveredCamera`, Kotlin `NikonSighting`); a held camera is a `heldByAnotherDevice` row, never picked.

Kotlin: `suspend fun multiviewSightings(listened: List<NikonSighting>, savedHosts: Collection<String>, excludedHosts: Set<String>): List<NikonSighting>` (Android's NSD/USB listing is the app's, so it is passed in).

Ruling during execution: a new `NikonSighting` struct was dropped because Kotlin already has `NikonSighting` as the twin of Swift `DiscoveredCamera`.

- [ ] Write failing tests (Swift `NikonDiscoveryTests`, Kotlin `NikonDiscoveryTest`, same names):
  `multiviewSightingsNeverDialsTheControlPortOrAnExcludedHost` (zero control dials, zero PTP Inits, no liveness dial to an excluded host, excluded rows absent, a held camera listed as not pickable) and
  `activeDiscoveryComparesExcludedHostsByTheirKey` (an excluded `" 192.168.1.31 "` still keeps `192.168.1.31` undialled).
- [ ] Run, see them fail (missing API; the active search dials the untrimmed excluded host).
- [ ] Implement: normalize excluded hosts with `PTPIPPairedHosts.normalizedHost` / `NikonHosts.normalizedHost` at the comparison; add `multiviewSightings` over the passive pass; Kotlin keeps held rows from its presence sweep.
- [ ] Run Nikon tests on both platforms; commit `feat(nikon): multiview sightings and normalized excluded hosts`.

### Task 2: Open a picked body with identity check

**Interfaces:**

```swift
public enum NikonMemberTiming { public static let reconnectSettle: Duration = .milliseconds(1200); public static let reopenSpacing: Duration = .seconds(5) }
public enum NikonMemberOpenRefusal: Hashable, Sendable { case hostInUse, alreadyMember, differentBody, noIdentity }
public enum NikonMemberOpenResult<Link: Sendable>: Sendable {
    case opened(Link, device: CameraDeviceID)
    case refused(NikonMemberOpenRefusal)
}
public final class NikonMemberOpener<Link: Sendable>: @unchecked Sendable {
    public init(settle: Duration = NikonMemberTiming.reconnectSettle, now:, sleep:, connect:, serialNumber:, close:)
    public func open(host: String, expectedSerial: String? = nil, members: Set<CameraDeviceID>, hostsInUse: Set<String>) async throws -> NikonMemberOpenResult<Link>
    public func close(_ link: Link, host: String) async
}
```

Kotlin: `class NikonMemberOpener<L : Any>`, `object NikonMemberTiming` (`RECONNECT_SETTLE: Duration = 1_200.milliseconds`, `REOPEN_SPACING: Duration = 5.seconds`; drifted from the planned `*_MILLIS` longs during execution), `sealed interface NikonMemberOpenResult<out L>`.

- [ ] Failing tests (Swift `NikonMultiviewTests`, Kotlin `NikonMultiviewTest`): `openReturnsTheBodyAndItsSerialDevice`, `openRefusesAHostInUseWithoutDialling`, `openClosesAndRefusesABodyAlreadyInTheGroup`, `openClosesAndRefusesADifferentBody`, `openClosesAndRefusesABodyWithoutASerial`, `openWaitsTheReconnectSettleAfterAClose`.
- [ ] Implement; a failed connect also starts the settle for that host.
- [ ] Run; commit `feat(nikon): identity-checked member open with reconnect settle`.

### Task 3: Auto LUT source

**Interfaces:** Swift `NikonMovieTone.monitorTransfer: MonitorTransfer`; `NikonRecordingTone` (value: `fileType: UInt32?`, `tones`, `apply(_:data:)`, `tone`, `transfer`); `NikonMemberControl.recordingTone` and `pollRecordingTone(on:) async -> NikonMovieTone?` (reads `movieFileType`, then only that codec's tone property; a failed read keeps the last value). Kotlin `enum class NikonMovieTone(label)` with `monitorTransfer` and `fromLabel`, `val CameraPropertySnapshot.recordingTone: NikonMovieTone?`.

- [ ] Failing tests: `recordingToneIsUnknownUntilTheCodecReads`, `recordingToneFollowsTheCodecsToneProperty`, `fixedToneCodecsNeedNoToneRead`, `pollRecordingToneReadsTheCodecThenItsToneOnly`; Kotlin `recordingToneMapsTheSnapshotsTone`, `recordingToneIsUnknownForAnUnnamedTone`.
- [ ] Implement; run; commit `feat(nikon): recording tone for multiview auto LUT`.

### Task 4: Bounded automatic recovery step

**Interfaces:**

```swift
public struct NikonMemberRepair: Hashable, Sendable {
    public enum Step: Hashable, Sendable { case none, restartLiveView, reopen, wait(until: MonotonicInstant), waitForOperator(WaitReason) }
    public enum WaitReason: Hashable, Sendable { case budgetSpent, takenOver }
    public static let missedFramesForStall = 3
    public init(settle: Duration = NikonMemberTiming.reconnectSettle, reopenSpacing: Duration = NikonMemberTiming.reopenSpacing)
    public mutating func frameArrived(); frameMissed(); streamStalled(); linkLost(at:); takenOver(); attemptFailed(at:); reset()
    public mutating func next(at: MonotonicInstant, beginAttempt: () -> Bool) -> Step
}
```

Ladder: a stall on a live link restarts live view in place once per episode; a stall after that, a lost link or a failed restart reopens (close, then `NikonMemberOpener.open`) no sooner than the settle after the loss and `reopenSpacing` after a failed reopen (5 s: the Android saved-profile busy handoff's settle, the gentlest re-Init cadence the integration already uses); every attempt first asks `beginAttempt` (the caller's `RecoveryBudget.beginAttempt`); a refusal or a take-over waits for the operator.

- [ ] Failing tests: `repairRestartsLiveViewInPlaceForAStall`, `repairReopensOnlyAfterTheSettle`, `repairSpacesFailedReopens`, `repairAsksTheBudgetBeforeEveryAttempt`, `repairWaitsForTheOperatorAfterATakeOver`, `aFrameEndsTheEpisode`.
- [ ] Implement; run; commit `feat(nikon): bounded member repair ladder`.

### Task 5: Docs and API snapshots

- [ ] `docs/nikon/README.md` section "Multiview prep (Plan 6)"; `docs/multicam/README.md` Nikon bullet.
- [ ] `python3 atlas/tools/atlas.py api --write --build` (derived data on OCScratch), `cd Android && ./gradlew updateKotlinAbi updateAndroidApi`.
- [ ] Gates: `swift build --build-tests -Xswiftc -strict-concurrency=complete`, `swift test --filter Nikon`, `./gradlew :nikon:test :nikon-wire:test :nikon:lint`, `atlas check`.
- [ ] Commit `docs(nikon): multiview prep` and `chore(api): nikon multiview snapshots`.

## Review fixes (2026-11-14)

The independent review of PR #348 found the opener and the ladder short of their own contract. Fixed, test first, Swift and Kotlin together:

- I1: `NikonMemberOpener.reopen(_ member:, host:, members:, hostsInUse:)` names the member a repair reopens; the member's own host and serial no longer refuse it. Test `reopenOpensTheMembersOwnHostAndChecksItsSerial`.
- I2: the opener takes `currentHolder` and refuses `heldByAnotherDevice` (result `heldBy`) without dialling. Test `openRefusesABodyAnotherDeviceHoldsWithoutDialling`.
- I3: a host whose open is in flight is refused `hostInUse`. Test `openRefusesAHostWhileAnOpenOfItIsInFlight`.
- I4: `multiviewSightingsNeverDialsTheControlPortOrAnExcludedHost` now excludes a saved-only member, so removing the exclusion fails it (checked with a temporary mutant on both platforms).
- I5: Kotlin closes a refused body under `NonCancellable` and starts the settle in `finally`. Test `refusalCloseCompletesWhenTheOpenIsCancelled`.
- I6: `NikonMemberRepair(attemptDeadline:)` (default `NikonSessionRecovery.attemptDeadline`, 30 s) fails a step that never reports back. Test `repairFailsAnAttemptThatOutlivesItsDeadline`.
- M1 (Swift): a write the member control sends updates `recordingTone` from its readback. Test `recordingToneFollowsAWriteTheControlSends`.
- Documented: M2, M4, M5, M6 (Swift repair is a value), M7, M8, M9, M11. M10: constant pins dropped from the tests.
- Not changed: M3 (a frame after a stall-made loss is real proof the link works; telling a stale frame of a dead link from it needs the link identity the coordinator holds, so Plan 6 filters frames by link). M1's larger form (deriving the tone from `reported`) needs the raw `MovFileType` in the snapshot, which keeps only the decoded label; a read the app applies through `update(_:)` still bypasses `recordingTone`. M12: no consumer run; the active-discovery change only excludes more hosts and no app uses the new API.

## Left for Plan 6

Wrapping these in `MultiviewMemberLink` and the coordinator's `RecoveryLedger`, the Add-camera rows and copy, the app's member pump calling `pollRecordingTone` and `NikonMemberRepair`, Auto LUT on by default, strict record, and the Nikon hardware pass on iOS and Android.
