# OpenCineMulticam

Manufacturer-independent multicam engine for the OpenCine camera monitor apps (plan work
package MULTI-01). It decides which cameras a group operation reaches, keeps per-camera results
honest, coordinates editor leases, resource admission and recovery budgets, and describes the
persisted layout. It works on [OpenCineCore](../OpenCineCore) values and the `CameraSession`
seam, so it never knows which manufacturer is behind an entry.

Status: pre-release. No app depends on it yet; app adoption is MULTI-02. Tested only against
OpenCineCore fakes, so nothing here is hardware-qualified, and production multicam stays in the
apps until an adapter replaces it per app.

## Import rules

- `Sources/OpenCineMulticam` imports only `Foundation` and `OpenCineCore` (Kotlin: the stdlib,
  coroutines and `com.opencapture.opencine.core`). Never SwiftUI, UIKit,
  Compose, a manufacturer integration, a transport or an app model. A test enforces the imports,
  the single package dependency and the absence of vendor and UI names.
- No behavior is chosen from an `IntegrationID` or a manufacturer name.
- The engine holds no runtime objects and runs no timers. Apps pass a `MulticamSnapshot` (latest
  `CameraSnapshot` per session, picture health per stream, busy entries, the clock) and, for
  submission, their `[CameraSessionID: any CameraSession]`.

## Public types

| Type | Purpose |
|---|---|
| `MulticamGroup` | Entries in slot order (stable `MonitorEntryID`s) and the staged entry; add, update (replace picture or session in place), move, remove, stage |
| `MulticamSnapshot` | The state the engine evaluates against at one instant |
| `GroupSummary`, `EntrySummary`, `RoleStatus` | Picture health, control-link state, telemetry freshness and reported recording, kept separate; camera counts deduplicated by session |
| `RecordPlan` | Group start/stop plan: targets deduplicated by control session, satisfied cameras, exclusions with reasons, strict or eligible-subset policy, `isCurrent` revalidation, bounded `submit` |
| `AdmissionFingerprint` | Per-target session, epoch, capability revision, authority, mode and reported recording; routine telemetry is excluded |
| `RecordSubmission`, `RecordResult`, `TargetOutcome` | Per-target outcomes (pending, accepted, confirmed, rejected, failed, timedOut, outcomeUnknown, superseded), mapped back to entries |
| `EditorLeases`, `EditorLease` | Per-entry settings/detail-view leases that retire when the entry's session, epoch or authority changes, or when closed or reopened; `refusal(for:in:at:)` answers "may this editor send now?" for an app's existing command path |
| `ResourceAdmission`, `ResourceRequest`, `ResourceClaim`, `ResourceBudget` | Route claims (camera access point, infrastructure network, USB interface, Bluetooth commissioning, bandwidth and decoder estimates) and feasibility with reasons; the app's qualification limit is an injected budget value |
| `RecoveryBudget`, `RecoveryLedger` | Independent bounded recovery budget per entry, restored after sustained health |
| `MulticamLayout` | Codable slot order, names, devices, routes and stage; the app chooses storage |

## Group record and stop (plan 8.2)

1. `RecordPlan.make(.start, policy:, entries:, in:, at:)` groups the requested entries by camera
   session, so two entries showing one camera get one command and share its result. Eligibility
   is Core's `CameraSnapshot.rejection(of:at:)` plus "has command authority", "has reported",
   "not busy", "has reported its recording state" (else `.rejected(.recordingStateUnknown)`)
   and "not transitioning". Cameras already in the requested state are `satisfied`.
2. Show `targets`, `satisfied` and `exclusions`. With `.strict` any exclusion refuses the plan;
   with `.eligibleSubset` the exclusions are listed and the rest proceed.
3. `submit` rebuilds the plan from fresh state and refuses with `.stale` unless it is equal.
   Battery, storage, setting values and timestamps never change a plan; a replacement session, a
   new control epoch, changed capabilities or authority, a mode change or a changed reported
   recording state do.
4. Each target receives one explicit `.startRecording` or `.stopRecording`, at most
   `maxConcurrent` in flight, with an optional deadline in its preconditions. The integration
   enforces timeouts.
5. `current` reads outcomes without waiting; `finished` waits for each. `outcome(for:in:)` maps a
   result to an entry and returns `.superseded` when the entry now shows a different session, so
   a late result never lands on a replacement.

Partial success is not a transaction. The engine never stops a camera because another failed and
never sends anything on close or removal; compensation is a separate operator intent.

Synchronization: a group command is coordinated best-effort dispatch with per-camera
confirmation. It is not synchronized recording, genlock or a shared clock.

## How apps adapt (MULTI-02)

- Pocket: `MultiviewSession` tiles become `MonitorEntryDescriptor`s with their tile UUIDs as
  entry IDs; `MultiviewRecordContext` becomes `RecordPlan.isCurrent`; `toggleAllRecording`
  resolves the operator's toggle to a direction from a fresh snapshot and submits the plan;
  the controls-only editor admission becomes an `EditorLease`; `MultiviewRecovery` keeps its
  transport ladder and reports attempts to `RecoveryLedger`; station provisioning cleanup stays
  in the integration.
- Nikon: `MulticamCoordinator` members become entries; `GroupRecordPlan`/`GroupRecordResult`
  map to `RecordPlan`/`RecordResult` with `.eligibleSubset`; `MulticamEligibilityPolicy` becomes
  resource claims plus a `ResourceBudget(qualifiedEntries: 4)`; the borrowed Live View session
  uses an `EditorLease`.
- Each app keeps its own qualified camera count, routes, copy and confirmation UI.

## Build and test

```sh
swift build
swift test
swift build --build-tests -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

`OpenCineCore` is resolved from the sibling checkout `../OpenCineCore`. CI checks out the commit
pinned in `opencine-pins.txt` with `scripts/checkout-opencine.sh` and verifies it; bump the pin
when Core changes. When Core is published the dependency becomes a URL with an exact version.

## Android

`Android/` is a standalone Gradle build with one plain Kotlin/JVM module, `multicam`
(`com.opencapture.opencine:multicam`, `0.1.0-SNAPSHOT`). It mirrors `Sources/OpenCineMulticam`
type for type with the same semantics and depends only on `com.opencapture.opencine:core` (the
Kotlin mirror of OpenCineCore) and kotlinx-coroutines. Kotlin 2.4.20, coroutines 1.11.0 and a
JVM 17 target match OpenCineCore/Android; warnings are errors and explicit API mode is on.

```sh
scripts/checkout-opencine.sh      # CI: pinned ../OpenCineCore; locally it only reports the SHA
cd Android && ./gradlew test      # JDK 17 or newer
```

Core is the sibling checkout `../OpenCineCore`, included as a named composite build
(`includeBuild("../../OpenCineCore/Android") { name = "opencinecore" ... }` in
`Android/settings.gradle.kts`), so tests use Core's fakes through `testFixtures`. Once Core is
published the `includeBuild` goes and the catalog coordinate stays. An app consumes this module
the same way it consumes Core: a named `includeBuild` of `OpenCineMulticam/Android` substituting
`com.opencapture.opencine:multicam` with `project(":multicam")`, next to Core's.

### Kotlin mapping

Package `com.opencapture.opencine.multicam`. Same names and semantics, in Kotlin idiom, following
OpenCineCore's mapping (payload-free cases are `enum class`, cases with payload a `sealed
interface`, Swift labels become parameter names: `make(direction, policy, entries, group,
state)`, `summary(state, telemetryMaxAge)`). Where they differ:

| Swift | Kotlin | Difference |
|---|---|---|
| `MulticamGroup`, `EditorLeases`, `RecoveryBudget`, `RecoveryLedger` (`mutating` structs) | mutable classes | Not values: confine each to its owner (no lock), no equality. `MulticamGroup.entries` is replaced on every change, so a list read earlier never changes. |
| `RecoveryLedger[entry]` get/set | `ledger[entry]` returns the live budget | Reading creates the entry's budget; mutate it in place. |
| `throws(MulticamGroupError)`, `throws(RecordSubmissionError)`, `throws(EditorLeaseRefusal)` | `MulticamGroupException`, `RecordSubmissionException`, `EditorLeaseException` | Each exception carries the Swift-shaped value (`error` / `refusal`). |
| `MulticamSnapshot` (vars) | class, read-only | Takes a camera list; `cameras` is the map keyed by session (last wins). |
| `EntrySummary.init(_:at:telemetryMaxAge:)`, `TargetOutcome.init(_:)` | `EntrySummary(entry, state, maxAge)`, `TargetOutcome(stage)` via companion `invoke` | |
| `RoleStatus<Value>` | `RoleStatus<out T>`: `Absent`, `Unreported`, `Reported(value)` | Covariant, as Core's `ObservedValue`. |
| `RecordSubmission.current(sessions:) async` | `current(sessions)`, not suspending | Core's Kotlin `receipt` does not suspend. `finished` suspends. |
| `submit(... maxConcurrent:)` task group | `coroutineScope` + `Semaphore` | Same bound; runs on the caller's dispatcher, so a confined session stays confined. |
| `EditorLeaseID = Identifier<IdentityKind.EditorLease>` | `@JvmInline value class EditorLeaseID(uuid)` | As Core's IDs. |
| `ResourceRequest.bitsPerSecond`, `ResourceBudget.bitsPerSecond` (`Int`) | `Long` | Swift `Int` is 64-bit. |
| `ResourceClaim.infrastructureNetwork(_)`, `.usbInterface(_)` | `InfrastructureNetwork(network)`, `UsbInterface(name)` | Unlabeled payloads get names. |
| `Codable` (`MulticamLayout`, claims, requests, budgets, direction, policy) | plain data classes and enums | No serialization, as in Core: the app maps `MulticamLayout` to its storage. Add kotlinx.serialization when a consumer needs it. |

### Test mapping

Suites and test names are the same (`Android/multicam/src/test`): `GroupTests` (2),
`EditorLeaseTests` (2), `ResourceAdmissionTests` (2), `RecoveryTests` (2), `GroupRecordTests` (9),
`ImportRuleTests` (1), 18 in all. Differences: `slotsSurviveReorderStagingAndSessionReplacement`
checks the layout value instead of a JSON round trip, and the import rule is
`engineImportsOnlyStdlibCoroutinesAndCoreAndNamesNoVendorOrUI` (imports `kotlin.*`,
`kotlinx.coroutines.*`, `com.opencapture.opencine.core.*` and `java.util.UUID` only; the module's
only dependencies are Core and coroutines; Core is the only included build).

## License

Apache 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
