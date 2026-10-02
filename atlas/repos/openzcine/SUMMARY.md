# openzcine

Nikon Z monitor app (iOS, watchOS, Wear OS, Android). Registered refs: `main` (the baseline),
the unmerged `feat/monitor-engine-port` candidate (shared UI targets, multicam, owner-keyed JNI)
and the `opencine/integration` candidate that consumes `opencine` (Core, Media, FrameIO, Apple,
Nikon; not the shared UI). Never describe one as another. The UI-03 engine-port candidate
(`opencine/ui-03-engine-port-candidate`, still on the retired OpenCineUI path) is superseded:
OpenZCine adopts shared UI and multicam fresh from OpenCine in a later work package (NIKON-01).

## Connections

- **Source-copy of `openpocketcine`** (candidate branch only): engine-port vendors
  `MonitorPresentation`, `MonitorUI` and Android `monitor-ui` by hand.
- Donor of the cube parser that `openpocketcine` adapted.
- **Consumes `opencine`** on `opencine/integration`: one local package reference `../../OpenCine`
  in `ios/Runner.xcodeproj`, `../OpenCine` in `Package.swift`, and one Gradle included build
  named `opencine`, pinned by one line in `opencine-pins.txt`.
- On `main`, the iOS app compiles `OpenZCineCore` sources directly; it does not consume the
  root Swift package. The engine-port Xcode project adds a local package reference.

## Where to start reading

| Topic | Paths |
|---|---|
| Products | `Package.swift`, `ios/Runner.xcodeproj/project.pbxproj`, `Apps/Android/settings.gradle.kts` |
| PTP properties and live view | `Sources/OpenZCineCore/PTPCameraProperties.swift`, `LiveViewWatchdog.swift`, `ios/Runner/NativeCameraSession.swift` |
| HDMI/UVC capture input | `ios/Runner/UVCVideoSource.swift`, `Apps/Android/app/src/main/kotlin/com/opencapture/openzcine/UvcCaptureSource.kt` |
| Frame.io request planning | `Sources/OpenZCineCore/Frameio/FrameioAPI.swift` |
| Owner-keyed JNI (engine-port only) | `Sources/OpenZCineAndroidFacade/AndroidSessionOwnerRegistry.swift` |
| Picture/control separation (engine-port only) | `Sources/OpenZCineCore/VideoSource.swift` |
| Multicam (engine-port only) | `ios/Runner/MulticamCoordinator.swift`, `Sources/OpenZCineCore/GroupRecord.swift` |

## Cross-repo gotchas

- The primary checkout holds dirty user spike work on another branch. Read through Git
  objects; edit only in a task worktree.
- The engine-port worktree lives in a directory named `main`. The directory name is not
  branch evidence; use `tools/atlas.py locate openzcine`.
- The contributed "R3D NE Monitor" LUT is app-scoped by permission. Never move it into a
  shared package (see `THIRD-PARTY-NOTICES.md`).
