# OpenCineMulticam

Manufacturer-independent multicam engine for the OpenCine camera monitor apps (plan work
package MULTI-01). It decides which cameras a group operation reaches, keeps per-camera results
honest, coordinates editor leases, resource admission and recovery budgets, and describes the
persisted layout. It works on [OpenCineCore](../core/README.md) values and the `CameraSession`
seam, so it never knows which manufacturer is behind an entry.

Status: pre-release. OpenPocketCine's Multiview (MULTI-02) and OpenZCine's multicam (NIKON-01)
depend on it. Tested against OpenCineCore
fakes, real `NikonCameraSession`s over scripted links and the apps' adapters, so nothing here is
hardware-qualified.

## Import rules

- `Sources/OpenCineMulticam` imports only `Foundation` and `OpenCineCore` (Kotlin: the stdlib,
  coroutines and `com.opencapture.opencine.core`). Never SwiftUI, UIKit,
  Compose, a manufacturer integration, a transport or an app model. A test enforces the imports,
  the single package dependency and the absence of vendor and UI names.
- No behavior is chosen from an `IntegrationID` or a manufacturer name.
- The engine holds no runtime objects and runs no timers. Apps pass a `MulticamSnapshot` (latest
  `CameraSnapshot` per session, picture health per stream, busy entries, the clock: `MonotonicInstant.now()` by default, the host reference every session stamps on) and, for
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
| `ResourceAdmission`, `ResourceRequest`, `ResourceClaim`, `ResourceBudget` | Route claims (camera access point, infrastructure network, USB interface, Bluetooth commissioning, bandwidth and decoder estimates) and feasibility with reasons; the app's qualification limit is an injected budget value. The explicit `qualification` overload consumes Core `MulticamQualification`; unknown and refused verdicts block multiview admission. The resource-only overload remains available for single connection feasibility. `ResourceClaim.claims(for:)` and `ResourceRequest(entry:device:route:picture:bitsPerSecond:)` map a Core `SavedRoute` (access point, infrastructure, hotspot as `hotspot:<network>`, USB and capture interface, plus commissioning for a Bluetooth route) |
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

- Pocket (done, MULTI-02): each tile owns one `DJICameraSessionAdapter` over a
  record-only tile port on its existing link and is an entry keyed by its tile
  UUID; the record confirmation holds a strict `RecordPlan` and submits it. The
  controls-only editor keeps its borrowed session but asks
  `EditorLeases.refusal(for:in:at:)` before every SET. `ResourceAdmission` combines
  the DJI configuration qualification with the app's
  `ResourceBudget(qualifiedEntries: 4)` before station provisioning; the same
  budget supplies the tile and saved-stage limits. Not adopted yet:
  `RecoveryLedger` (the tile repair ladder keeps its own budget) and
  `GroupSummary`.
- Nikon (NIKON-01): each member is an entry keyed by its body serial with its
  own `NikonCameraSession` over an OpenCineNikon `NikonMemberControl`. Group record
  is an `.eligibleSubset` `RecordPlan` with per-member `RecordResult`s. Saved-path
  admission uses `NikonMulticamPolicy` plus `ResourceAdmission` with
  `ResourceBudget(qualifiedEntries: 4)`. Photography observation is optional
  before connect: an eligible route may open while mode is unknown, and
  camera-reported mode is checked after connect before any record operation.
  A member borrowed into full Live View holds an `EditorLease`, is `busy` for
  group plans and keeps its session (no CloseSession).
  Tests: `Tests/OpenCineNikonTests/NikonMulticamTests.swift`.
- Each app keeps its own qualified camera count, routes and policies. The stage UI is shared:
  OpenCineAppKit `MultiviewStage` takes `MultiviewTile` values and a `MultiviewRecordContext`
  over the app's `RecordPlan` ([appkit](../appkit/README.md#multiview-stage)). Pocket maps its
  session tiles (`MultiviewTileValues`); Nikon maps its members in `MulticamStage` and words the
  eligible-subset confirmation with `MultiviewRecordContext.prompt`.

## Build and test

```sh
swift build
swift test
swift build --build-tests -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

`OpenCineCore` is a target of the same package (root `Package.swift`); the target edge
`OpenCineMulticam -> OpenCineCore` is the only one allowed (`ImportRuleTests`).

## Android

`:multicam` is a plain Kotlin/JVM module of the platform Gradle build (`Android/`), `multicam`
(`com.opencapture.opencine:multicam`, `0.1.0-SNAPSHOT`). It mirrors `Sources/OpenCineMulticam`
type for type with the same semantics and depends only on `com.opencapture.opencine:core` (the
Kotlin mirror of OpenCineCore) and kotlinx-coroutines. Kotlin 2.4.20, coroutines 1.11.0 and a
JVM 17 target match `:core`; warnings are errors and explicit API mode is on.

```sh
cd Android && ./gradlew :multicam:test   # JDK 17 or newer
```

Core is `project(":core")` in the same build, so tests use Core's fakes through `testFixtures`.
An app consumes this module like the others: its one named `includeBuild` of `OpenCine/Android`
(`name = "opencine"`) substitutes `com.opencapture.opencine:multicam` with `project(":multicam")`.

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
| `ResourceClaim.claims(for:)`, `ResourceRequest(entry:device:route:picture:bitsPerSecond:)` | `ResourceClaim.claims(route)`, secondary constructor `ResourceRequest(entry, device, route, picture, bitsPerSecond)` | |
| `Codable` (`MulticamLayout`, claims, requests, budgets, direction, policy) | plain data classes and enums | No serialization, as in Core: the app maps `MulticamLayout` to its storage. Add kotlinx.serialization when a consumer needs it. |

### Test mapping

Suites and test names are the same (`Android/multicam/src/test`): `GroupTests` (2),
`EditorLeaseTests` (2), `ResourceAdmissionTests` (4), `RecoveryTests` (2), `GroupRecordTests` (9),
`ImportRuleTests` (1), 20 in all. Differences: `slotsSurviveReorderStagingAndSessionReplacement`
checks the layout value instead of a JSON round trip, and the import rule is
`engineImportsOnlyStdlibCoroutinesAndCoreAndNamesNoVendorOrUI` (imports `kotlin.*`,
`kotlinx.coroutines.*`, `com.opencapture.opencine.core.*` and `java.util.UUID` only; the module's
only dependencies are Core and coroutines; Core is the only included build).

## License

Apache 2.0. See the root [LICENSE](../../LICENSE) and [NOTICE](../../NOTICE).
