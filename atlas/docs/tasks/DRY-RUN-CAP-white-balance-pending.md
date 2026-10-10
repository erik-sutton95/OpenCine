# DRY-RUN-CAP: show white balance as pending until the camera confirms it

Status: proposed (**dry run**: a workflow exercise; no app or package was changed)
Requested scope: plan only. Exercises [EXECUTION.md](../EXECUTION.md) for one capability change
spanning two integrations. No merge, tag, publication or release is authorized.

Illustrative request: "When I change white balance, the control should show the requested
value as pending until the camera actually reports it, on both the DJI and Luna apps."
(Plan 5.4 and 7.3: an accepted command is not a confirmed setting; Luna settings can take
seconds to read back.)

## Source baseline

- `openpocketcine` @ `27b15028e86d93798c802ddb56c7c474a30bb4c7`: DJI WB commands and status in
  `Sources/OpenPocketViewCore/Commands.swift`, `CameraStatus.swift`, `CameraControl.swift`;
  UI call sites `ios/OpenPocketCine/CameraSession.swift`, `CaptureQuickControl.swift`.
- `openinstacine` @ `35b6f33b20cbd791a4c24b6380046f180f1ee454`: Luna WB in
  `Adapters/Insta360Protocol/Sources/Insta360Protocol/LunaControl.swift` (+ `LunaControlTests`),
  `Adapters/Insta360Apple/Sources/Insta360Apple/LunaCameraBackend.swift`,
  `ios/OpenInstaCine/CameraSessionControls.swift`; Kotlin
  `Apps/Android/luna-adapter/src/main/kotlin/com/opencapture/openinstacine/luna/LunaControl.kt`.
- Nominal contract: `Sources/MonitorContracts/CameraBackend.swift` in Insta already names
  `whiteBalanceMode/Kelvin/Tint` but the Apple control path bypasses it (plan 9.4).
- Proposed common home: `opencinecore` (candidate, CORE-01) for a command receipt
  (`accepted` versus `confirmed`) and an observation with provenance.
- `atlas impact opencinecore --include-candidates`: no consumers yet (no edges). Impact must
  therefore be planned by hand, which this brief records.

## Ownership

- Interface owner (one agent): `opencinecore` command receipt and setting observation types,
  with fakes for a DJI-like and a Luna-like delayed readback. Nobody else edits these types;
  integration agents report needed changes to the owner.
- Agent DJI: Pocket task worktree; maps DUML WB set plus status readback onto the receipt.
- Agent Luna: Insta task worktree; maps Luna request acceptance plus delayed readback, Swift
  and Kotlin, with the same semantic test cases.
- Shared UI projection (pending indicator in the WB control): `opencineui` owner, after both
  integrations produce the receipt. Until UI adoption, this is Pocket's `Sources/MonitorUI`
  with the Insta copy following by sync.
- Coordination seam: the receipt and observation types. One reviewed candidate revision of
  `opencinecore` is the contract both integrations build against (relative path dependency on
  task branches, ADR 0002).

## Implementation (dependency order)

1. Core owner: add the types and fake-based tests in `opencinecore`; record the candidate SHA
   in `compat/candidates.json`.
2. In parallel, against that SHA: Agent DJI in `openpocketcine`, Agent Luna in
   `openinstacine`. Each adds tests that an accepted-but-unconfirmed change stays pending and
   that a timeout is distinguishable from a rejection.
3. UI owner: show pending from the receipt, never from the requested value alone.
4. Validate each app separately at its own branch SHA plus the same `opencinecore` SHA.

## Completion gate

- In both apps, the WB control shows requested-pending, then the camera-reported value; a
  rejected or timed-out change returns to the reported value with a reason.
- Automated: `opencinecore` tests; Pocket `just swift-test` and `just android-check`; Insta
  `just core-test` and `just android-check` (each repo's own commands).
- Hardware: Pocket 4 Pro WB readback and Luna Ultra WB readback on iOS and Android:
  **untested** until run. The Luna Android path has never been verified on hardware
  (BASE-01 qualification ledger).
- Consumer check: Nikon is not a consumer of this change; it is listed as unaffected rather
  than skipped silently.

## Rollback

- Each app reverts its integration commit independently; the old direct command path is
  restored behind one app-side switch (plan CORE-02). Do not run both command paths at once.

## Handoff

- Commits on four task branches (Core, Pocket, Insta, UI owner), none merged by agents.
- Release order once authorized: publish the `opencinecore` version, then each app pins it
  in its own pull request (ADR 0007). Pocket and Insta can ship in either order.
- Atlas after merge: add `contract` edges from each app to `opencinecore` with manifest
  evidence; set `opencinecore` to `active`.

## What the dry run showed

- A brand-new seam has no edges, so `impact` correctly reports nothing; the brief carries the
  planned consumers explicitly instead of trusting an empty graph.
- `check` will reject the edges if anyone points `opencinecore` back at an app or UI package.
