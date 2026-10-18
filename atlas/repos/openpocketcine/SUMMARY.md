# openpocketcine

DJI Osmo Pocket monitor app for iOS, watchOS and Android. Pocket's pre-refactor main is the common UI/UX reference. Build and test rules live in the app's `AGENTS.md`.

## Connections

Public main consumes OpenCine through one sibling Swift package and one Android included build named `opencine`, pinned in `opencine-pins.txt`. Shared UI, app composition, media tools, DJI protocol/runtime, motion, relay and multicam live in OpenCine. Historical UI extraction attribution stays recorded in the platform notices; it is not a current copy-sync workflow.

## Where to start reading

- `Package.swift`, `ios/project.yml`, `Apps/Android/settings.gradle.kts`: package and native consumers.
- `ios/OpenPocketCine/`: native session, live/media host values and camera/OS services.
- `Apps/Android/app/src/main/kotlin/com/opencapture/openpocketcine/session/AppSessionHost.kt`: Android host services for the shared DJI session.
- `Apps/Android/app/src/main/kotlin/com/opencapture/openpocketcine/media/Media3PlaybackPort.kt`: admitted native playback adapter.
- `Sources/OpenPocketViewCore/`, `Sources/OpenPocketCineAndroidFacade/`: remaining app values and JNI host exports. DJI session/JNI exports belong to OpenCine.
- `ios/OpenPocketCine/Frameio/`: host credentials, authentication and delivery services.

## Cross-repo gotchas

Shared behavior changes belong in OpenCine and require relevant adoption and verification in every thin app. A package pin and passing compile do not prove that an app supplies all required values/actions. Historical pre-migration refs and graph snapshots are navigation provenance, not evidence of current behavior. Read canonical checkouts through Git objects; edit only task-owned worktrees.
