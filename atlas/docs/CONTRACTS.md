# Cross-repository contracts

Links to the source that owns each seam. The atlas does not restate API details; read them at
the pinned revision (`python3 tools/atlas.py locate <id>` for the checkout).

## Seams that exist at the baselines

| Seam | Owner and source | Consumers | Notes |
|---|---|---|---|
| Shared presentation and SwiftUI products `MonitorPresentation`, `MonitorUI` | `openpocketcine`: `Package.swift`, `Sources/MonitorPresentation`, `Sources/MonitorUI` | Copied into `openinstacine`; vendored on `openzcine` engine-port | Becomes `opencineui` (candidate) |
| Compose design system `monitor-ui` | `openpocketcine`: `Apps/Android/monitor-ui` (see its `README.md` "Public presentation seams") | Copied into `openinstacine`; vendored on `openzcine` engine-port | Becomes `opencineui` Android |
| Pocket-to-Insta sync | `openinstacine`: `scripts/sync-openpocketcine.sh`, `docs/implementation/openpocketcine-sync-commit.txt` | `openinstacine` | `LUNA_OWNED` and `OSMO_ONLY` lists define what Insta owns |
| Nominal camera backend `MonitorContracts.CameraBackend` | `openinstacine`: `Sources/MonitorContracts/CameraBackend.swift` | Insta Apple app | Not yet the real control path (plan 9.4) |
| Kotlin camera API `core-api` | each app: `Apps/Android/core-api` | that app only | Separate per app today |
| Swift JNI facades `OpenPocketCineAndroid`, `OpenZCineAndroid` | each app's `Package.swift` and `Sources/*AndroidFacade` | that app's Android build | Owner-keyed registry exists only on the Nikon engine-port |

## Proposed seams (candidate repositories)

| Seam | Planned owner | Work package |
|---|---|---|
| Identity, observation, setting descriptor, command receipt, monitoring entry values | `opencinecore` | CORE-01 |
| Injected theme and brand configuration | `opencineui` (ADR 0004) | UI-01/UI-02 |
| Multicam engine over Core values | `OpenCineMulticam` (not created) | MULTI-01 |

## Dependency direction (enforced)

`python3 tools/atlas.py check` rejects these build edges (`library`, `contract`, `generates`),
whether authored or found in manifests with `--sources`:

- Core never depends on UI, vendor, multicam or app code.
- Vendor packages never depend on UI or apps.
- Multicam never depends on vendor packages, UI or apps.
- UI never depends on vendor packages or apps.
- Nothing depends on `opencapture-atlas`.
- No build cycles.

## Decisions

Cross-repository decisions live in [architecture/decisions/](architecture/decisions/). The
full plan copy is [architecture/platform-plan.md](architecture/platform-plan.md).
