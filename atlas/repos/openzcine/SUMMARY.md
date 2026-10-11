# openzcine

Nikon Z cinema monitor app for iOS, watchOS, Android and Wear OS. Public main consumes OpenCine shared UI, app composition, media, multicam and Nikon integration. Historical engine-port refs remain provenance, not the current composition.

## Connections

The root Swift package and native Runner/Watch targets consume OpenCine; Android includes its one build named `opencine`. `opencine-pins.txt` records the exact shared revision. Nikon PTP session/JNI and property policy live in OpenCine; app adapters own native picture, admitted host services and brand capabilities.

## Where to start reading

- `Package.swift`, `ios/Runner.xcodeproj/project.pbxproj`, `Apps/Android/settings.gradle.kts`: actual consumers.
- `ios/Runner/NativeAppRoot.swift`, `MonitorUnified.swift`: observed native camera facts and common monitor bindings.
- `ios/Runner/MediaBrowser.swift`, `NikonPlaybackNativePort.swift`: shared gallery/playback composition and captured native item owner.
- `ios/Runner/MulticamCoordinator.swift`, `MulticamStage.swift`: host multicam composition.
- `ios/Runner/Frameio/`, `Sources/OpenZCineAndroidFacade/FrameioWire.swift`: delivery host and wire adapters.
- OpenCine `Sources/OpenCineNikon/`, `Sources/OpenCineNikonAndroid/`, `Android/nikon/`: portable Nikon integration and owner-keyed JNI.

## Cross-repo gotchas

Shared behavior changes belong in OpenCine and require relevant adoption and verification in every thin app. A package pin and passing compile do not prove that an app supplies all required values/actions. Historical pre-migration refs and graph snapshots are navigation provenance, not evidence of current behavior. Read canonical checkouts through Git objects; edit only task-owned worktrees.

The contributed R3D NE Monitor LUT remains app-scoped by permission; never move it into the shared package. Codec/recording profile does not by itself prove the live preview or a saved clip's transfer curve. Read actual descriptors and per-file metadata; preserve unknown.
