# openpocketcine

DJI Osmo Pocket monitor app (iOS, watchOS, Android). The donor for the shared UI 2.0
design system and for Multi View. Build and test instructions live in the repo's own
`AGENTS.md`; this file is only a map.

## Connections

- **Donor to `openinstacine`** (source-copy, live): Insta copies Pocket's shared Swift
  targets, tests, iOS shell and Android shell. A Pocket change in those paths is not in
  Insta until someone runs Insta's sync and reviews it.
- **Donor to `openzcine` engine-port** (source-copy, candidate branch only).
- **Donor to `opencine`** (candidate): UI-01/UI-02 extracted `MonitorPresentation`,
  `MonitorUI` and Android `monitor-ui` from the frozen BASE-01 revision.
- **Consumes `opencine`** on `opencine/integration` (candidate): one sibling path `../OpenCine`
  and one Gradle included build named `opencine`, pinned by one line in `opencine-pins.txt`.
- Took its cube parser from `openzcine` once (see `THIRD-PARTY-NOTICES.md`).

## Where to start reading

| Topic | Paths |
|---|---|
| Swift products and target direction | `Package.swift`, `ios/project.yml` |
| Shared presentation policy | `Sources/MonitorPresentation/` |
| Shared SwiftUI design system | `Sources/MonitorUI/` (theme: `MonitorTheme.swift`) |
| Compose design system | `Apps/Android/monitor-ui/` |
| DJI protocol core (stays vendor-owned) | `Sources/OpenPocketViewCore/` (for example `DumlFrame.swift`) |
| Color science and log analysis | `Sources/OpenPocketViewCore/LiveColorScience.swift`, `LogColorTransform.swift` |
| Multi View hosts, leases, record plan | `ios/OpenPocketCine/MultiviewStageCanvas.swift`, `MultiviewSession.swift`, `MultiviewCameraSettings.swift`, `MultiviewRecordAction.swift` |
| Android native renderer | `Apps/Android/app/src/main/cpp/opc_vulkan.cpp` |
| Frame.io (iOS) | `ios/OpenPocketCine/Frameio/` |

## Cross-repo gotchas

- The shared checkout is used live by other sessions. Read it through Git objects or a
  task worktree; never switch its branch.
- Shared-UI edits here propagate to Insta only through its sync script, and to Nikon
  only by hand. Record the donor SHA when copying.
