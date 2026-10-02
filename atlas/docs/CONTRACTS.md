# Cross-repository contracts

Links to the source that owns each seam. The atlas does not restate API details; read them at
the pinned revision (`python3 tools/atlas.py locate <id>` for the checkout).

## Seams that exist at the baselines

| Seam | Owner and source | Consumers | Notes |
|---|---|---|---|
| Shared presentation and SwiftUI products `MonitorPresentation`, `MonitorUI` | `openpocketcine`: `Package.swift`, `Sources/MonitorPresentation`, `Sources/MonitorUI` | Copied into `openinstacine`; vendored on `openzcine` engine-port | Moved to `opencine` (candidate) |
| Compose design system `monitor-ui` | `openpocketcine`: `Apps/Android/monitor-ui` (see its `README.md` "Public presentation seams") | Copied into `openinstacine`; vendored on `openzcine` engine-port | Moved to `opencine` `Android/monitor-ui` |
| Pocket-to-Insta sync | `openinstacine`: `scripts/sync-openpocketcine.sh`, `docs/implementation/openpocketcine-sync-commit.txt` | `openinstacine` | `LUNA_OWNED` and `OSMO_ONLY` lists define what Insta owns |
| Nominal camera backend `MonitorContracts.CameraBackend` | `openinstacine`: `Sources/MonitorContracts/CameraBackend.swift` | Insta Apple app | Not yet the real control path (plan 9.4) |
| Kotlin camera API `core-api` | each app: `Apps/Android/core-api` | that app only | Separate per app today |
| Swift JNI facades `OpenPocketCineAndroid`, `OpenZCineAndroid` | each app's `Package.swift` and `Sources/*AndroidFacade` | that app's Android build | Owner-keyed registry exists only on the Nikon engine-port |

## Shared seams in the platform repository (candidate)

Every shared seam now lives in `opencine` and keeps its product name and Gradle coordinate; the
apps' `opencine/integration` branches consume them. Read them at the pinned revision:

| Seam | Source in `opencine` | Work package |
|---|---|---|
| Identity, observation, setting descriptor, command receipt, monitoring entry values | `Sources/OpenCineCore`, Kotlin `Android/core` (fakes: `OpenCineCoreTestSupport`, `:core` test fixtures) | CORE-01 |
| Injected theme and brand configuration | `Sources/MonitorUI/MonitorTheme.swift`, `Android/monitor-ui` (ADR 0004) | UI-01/UI-02 |
| Multicam engine over Core values | `Sources/OpenCineMulticam`, `Android/multicam` | MULTI-01 |
| Vendor sessions behind `CameraSession` | `Sources/OpenCineDJI`, `Sources/OpenCineNikon`, `Sources/Insta360Apple`, `Android/insta360-luna` | VENDOR-01..03 |
| App shell contract for Luna | `Android/insta360-shell` | CORE-API |

## Dependency direction (enforced)

`python3 tools/atlas.py check` rejects these edges between the products of `opencine` (the
target dependencies in `Package.swift` and the `project(":x")` dependencies of each Gradle
module, layers from `repos/opencine/meta.json`), and the same rules for build edges between
repositories (`library`, `contract`, `generates`), authored or found in manifests with
`--sources`:

- Core never depends on UI, an integration (vendor), multicam or app code.
- Integrations never depend on UI or apps.
- Multicam never depends on integrations, UI or apps.
- UI never depends on integrations or apps.
- Nothing depends on the harness (except the harness) or on the atlas; the platform declares
  no package dependencies.
- No build cycles.

## Decisions

Cross-repository decisions live in [architecture/decisions/](architecture/decisions/). The
full plan copy is [architecture/platform-plan.md](architecture/platform-plan.md).
