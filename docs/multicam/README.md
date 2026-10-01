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

- `Sources/OpenCineMulticam` imports only `Foundation` and `OpenCineCore`. Never SwiftUI, UIKit,
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
| `EditorLeases`, `EditorLease` | Per-entry settings/detail-view leases that retire when the entry's session, epoch or authority changes, or when closed or reopened |
| `ResourceAdmission`, `ResourceRequest`, `ResourceClaim`, `ResourceBudget` | Route claims (camera access point, infrastructure network, USB interface, Bluetooth commissioning, bandwidth and decoder estimates) and feasibility with reasons; the app's qualification limit is an injected budget value |
| `RecoveryBudget`, `RecoveryLedger` | Independent bounded recovery budget per entry, restored after sustained health |
| `MulticamLayout` | Codable slot order, names, devices, routes and stage; the app chooses storage |

## Group record and stop (plan 8.2)

1. `RecordPlan.make(.start, policy:, entries:, in:, at:)` groups the requested entries by camera
   session, so two entries showing one camera get one command and share its result. Eligibility
   is Core's `CameraSnapshot.rejection(of:at:)` plus "has command authority", "has reported",
   "not busy" and "not transitioning". Cameras already in the requested state are `satisfied`.
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

Android (a Kotlin mirror consuming `com.opencapture.opencine:core`) is not written yet.

## License

Apache 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
