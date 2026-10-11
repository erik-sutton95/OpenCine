# openinstacine

Insta360 Luna monitor app for iOS, watchOS and Android. It consumes the common OpenCine shell and its Luna integration. Start with the app's `README.md` and `docs/DEVELOPMENT.md`.

## Connections

Public main uses the one sibling OpenCine package and Android included build, with the exact revision in `opencine-pins.txt`. Shared UI, app composition, media processing, common services and Luna protocol/transport belong in OpenCine. Historical Pocket-copy attribution is preserved; the retired copy-sync script is not the current propagation path.

## Where to start reading

- `Package.swift`, `ios/project.yml`, `Apps/Android/settings.gradle.kts`: native consumers and app-owned targets.
- `ios/OpenInstaCine/CameraSession.swift`, `CameraSessionCore.swift`, `CameraSessionControls.swift`: Luna session host bindings.
- `ios/OpenInstaCine/AppDiagnostics.swift`: host reporting/privacy policy.
- `Apps/Android/monitor/src/main/kotlin/com/opencapture/openinstacine/monitor/session/PocketCameraSession.kt`: Android Luna host; retained filename is not a DJI protocol implementation.
- `Apps/Android/monitor/src/main/kotlin/com/opencapture/openinstacine/monitor/media/Media3PlaybackPort.kt`: native playback adapter.
- OpenCine `Sources/Insta360Protocol/`, `Sources/Insta360Apple/`, `Android/insta360-luna/`: protocol and platform integration ownership.

## Cross-repo gotchas

Shared behavior changes belong in OpenCine and require relevant adoption and verification in every thin app. A package pin and passing compile do not prove that an app supplies all required values/actions. Historical pre-migration refs and graph snapshots are navigation provenance, not evidence of current behavior. Read canonical checkouts through Git objects; edit only task-owned worktrees.

Preserve Luna approval/keychain namespaces. Inherited multicam controls alone do not establish that one joined camera access point can serve two Luna cameras. Capability and physical evidence determine support.
