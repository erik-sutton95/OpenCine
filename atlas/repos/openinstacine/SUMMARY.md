# openinstacine

Insta360 Luna monitor app (iOS, watchOS, Android). Built on a synchronized copy of the
OpenPocketCine shell plus Luna adapters. The repo has no `AGENTS.md`; start from its
`README.md` and `docs/DEVELOPMENT.md`.

## Connections

- **Source-copy of `openpocketcine`** (live): `scripts/sync-openpocketcine.sh` re-copies
  shared Swift targets, tests, the renamed iOS shell and a tools subset. The last synced
  Pocket commit is recorded in `docs/implementation/openpocketcine-sync-commit.txt`.
  The Android shell (`Apps/Android/monitor`, `monitor-ui`, `core-api`) was copied by hand.
- Its settable-accent `MonitorTheme` is the theme donor for the shared UI in `opencine` (ADR 0004).
- **Consumes `opencine`** on `opencine/integration` (candidate): one sibling path `../OpenCine` and
  one Gradle included build named `opencine`, pinned by one line in `opencine-pins.txt`.

## Where to start reading

| Topic | Paths |
|---|---|
| Products | `Package.swift`, `Adapters/Insta360Protocol/Package.swift`, `ios/project.yml` |
| Nominal neutral contract | `Sources/MonitorContracts/CameraBackend.swift` |
| Luna Apple adapter | `Adapters/Insta360Apple/Sources/Insta360Apple/LunaCameraBackend.swift` |
| Luna wire protocol (Swift) | `Adapters/Insta360Protocol/Sources/Insta360Protocol/` |
| Luna wire protocol (Kotlin) | `Apps/Android/luna-adapter/src/main/kotlin/com/opencapture/openinstacine/luna/` |
| Luna-owned iOS seams | `ios/OpenInstaCine/CameraSession.swift`, `CameraSessionControls.swift`, `LunaShellMapping.swift`, `PictureEVMeter.swift` |
| Which files the sync never touches | `LUNA_OWNED` and `OSMO_ONLY` in `scripts/sync-openpocketcine.sh` |

## Cross-repo gotchas

- Files under `Sources/MonitorUI`, `Sources/MonitorPresentation` and most of `ios/` are
  Pocket-owned copies. Fix them in Pocket (or in `opencine` once adopted), not here, or the
  next sync will conflict.
- `docs/implementation/architecture.md` names paths that do not exist at the baseline;
  trust manifests over it.
- Inherited Multi View code is not evidence that Luna Multi View is supported.
