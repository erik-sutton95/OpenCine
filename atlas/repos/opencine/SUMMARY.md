# opencine (candidate)

The one platform repository: every shared Swift product and Android module of the three apps,
plus this atlas (`atlas/`). Formerly seven repositories (OpenCineCore, OpenCineUI,
OpenCineMulticam, OpenCineDJI, OpenCineNikon, OpenCineInsta360, OpenCineHarness) and
opencapture-atlas, merged with their history (ADR 0010). One version for everything. Status
`candidate`: local only, consumed by the apps' candidate branches through one sibling path
(`../OpenCine`) and one Gradle included build named `opencine`.

## Layers (meta.json `layers`; `atlas check` enforces plan 3.4 per target and module)

| Layer | Swift products (targets) | Gradle modules | Area docs |
|---|---|---|---|
| core | OpenCineCore, OpenCineMedia, OpenCineFrameIO, OpenCineMotion, OpenCineRelay, OpenCineApple, OpenCineCoreTestSupport | `:core`, `:media`, `:vulkan` | `docs/core/` |
| ui | MonitorPresentation, MonitorUI | `:monitor-ui` | `docs/ui/` |
| multicam | OpenCineMulticam | `:multicam` | `docs/multicam/` |
| vendor | OpenCineDJI, OpenCineNikon, Insta360Protocol, Insta360Apple, Insta360AppleTestSupport (CKcp target) | `:insta360-shell`, `:insta360-luna` | `docs/dji/`, `docs/nikon/`, `docs/insta360/` |
| harness | none (HarnessEngine, HarnessComposition, HarnessTests: dev-only, SIMULATED) | none | `docs/harness/` |

Core depends on nothing above it; integrations never on UI; Multicam never on an integration or
UI; UI never on an integration; nothing builds against the harness or the atlas. The package
declares no package dependencies.

## Where to start reading

| Topic | Paths |
|---|---|
| Products and target edges | `Package.swift`, `Android/settings.gradle.kts`, `Android/<module>/build.gradle.kts` |
| Common camera contracts | `Sources/OpenCineCore/`, Kotlin `Android/core/` |
| Media math, Apple runtime, Vulkan renderer | `Sources/OpenCineMedia/`, `Sources/OpenCineApple/`, `Android/vulkan/` |
| Shared UI 2.0 | `Sources/MonitorUI/`, `Sources/MonitorPresentation/`, `Android/monitor-ui/` |
| Integrations | `Sources/OpenCineDJI/`, `Sources/OpenCineNikon/`, `Sources/Insta360*/`, `Android/insta360-*/` |
| Cross-brand harness and findings | `Sources/Harness*/`, `Tests/HarnessTests/`, `docs/harness/TOPOLOGY.md` |

Build, test and agent rules: the repository's root `README.md` and `AGENTS.md`.
