# Compatibility inventory (thin-app migration)

What is still a compatibility surface on `integration/thin-app`, in OpenCine and in each app, and
why it stays: every remaining shim, facade, typealias bridge, forwarder, source-sync remnant and
app-owned copy of a shared owner. Companion of [RETIRED-OWNERS.md](RETIRED-OWNERS.md) (what
already moved) and evidence for the ledger rows `pocket.compat`, `insta.compat` and `nikon.compat`.

Status: candidate. Measured on the union recorded as `opencine-thin-app` in
[atlas/compat/candidates.json](../../atlas/compat/candidates.json) (OpenCine `aed102b9`,
OpenPocketCine `3e429797`, OpenInstaCine `ed7e0089`, OpenZCine `25a49155`) and on the compat lane's
`lane/compat` heads with the retirements listed below (OpenCine `54e2d41` plus this document,
OpenPocketCine `2216acb5`, OpenInstaCine `32caba6`, OpenZCine `d462fcaf`). The retirements remove
about 3,780 production lines from the apps (Pocket -1,507, Insta -1,905, Nikon -364), only dead or
purely forwarding code, with no behavior change. Physical hardware is untested.

## Reasons

| Verdict | Meaning |
|---|---|
| app composition | Wires the shared shell with the app's integration list, brand, slots or log subsystem |
| brand wire format | A JNI class, member or exported symbol, a library name, a saved key, a keychain service, a stored raw value or a network wire version that existing installs or the other platform depend on |
| SDK adapter | An adapter over a vendor SDK or an OS API that only this app uses |
| main parity | Needed for the app to behave like its `main`; no shared owner covers it yet |
| Nikon feature | Kept Nikon behavior (MF strip, e-VR, passive discovery and admission, N-Log/R3D calibration, photography and HDMI states) |
| retire (follow-up) | Should go; listed with what blocks it |

## Duplication exit

`python3 atlas/tools/atlas.py dupes --candidate opencine-thin-app` reads each app at the
candidate's recorded commit (`--candidate` never writes the baseline). "Union when this lane
started" is OpenCine `bb500df8` with OpenPocketCine `3e429797`, OpenInstaCine `ed7e0089` and
OpenZCine `0b7e555e`; "After the compat lane" is the four `lane/compat` heads named in the Status
line. The registry refs still name the apps' pre-migration `opencine/integration` commits, so a
plain `atlas dupes --check` on `integration/thin-app` reports growth until those refs move after
the authorized merge.

| Pair (normalized lines) | Registry refs (pre-migration) | Union when this lane started | After the compat lane |
|---|---:|---:|---:|
| OpenCine / OpenInstaCine | 28,525 | 8,497 | 7,749 |
| OpenCine / OpenPocketCine | 13,197 | 658 | 504 |
| OpenCine / OpenZCine | 2,117 | 498 | 466 |
| OpenInstaCine / OpenPocketCine | 55,295 | 27,599 | 25,291 |
| OpenInstaCine / OpenZCine | 716 | 227 | 206 |
| OpenPocketCine / OpenZCine | 1,687 | 275 | 248 |

What the remaining numbers are:

- OpenCine / OpenInstaCine: Insta's forks of DJI-only `OpenCineDJI` / `Android/dji` owners
  (exposure lock, face-priority exposure, gamepad map, joystick and touch mapping, zoom stops,
  privacy redaction). Insta cannot link the DJI integration, and the Luna build reaches these, so
  they wait for a neutral owner (follow-up I-3 below).
- OpenInstaCine / OpenPocketCine: Insta's Pocket-derived iOS and Android shell code that has no
  OpenCine owner yet (reliability reporting, live chrome, assists views, watcher views, gamepad).
  Nothing syncs it any more; each area is a follow-up move into OpenCine (I-4).
- OpenCine / OpenPocketCine and OpenCine / OpenZCine: function blocks only, no whole files. Most
  are small idioms or the copies listed as follow-ups (false-colour lattice, tracking bracket,
  relay and watch wires, frozen test donors).

## OpenCine (kept for the apps)

| Item | Verdict |
|---|---|
| JNI classes `com.opencapture.openpocketcine.feed.OpcVulkan` (legacy app package), `com.opencapture.opencine.dji.DjiNative`, `com.opencapture.opencine.nikon.NikonNative` and their exports | brand wire format |
| Android `dji`: `PocketCameraSession`, `PocketSessionHost`, `PocketPhase`, `PocketControlState`, `PocketControlPort`, with the neutral aliases `DjiCameraSession` and `DjiSessionHost` | retire (follow-up O-1): the Pocket-named shared session of SHELL-04. Pocket uses `DjiCameraSession` 27 times; rename the classes, keep the old names as aliases one release, then remove (add, migrate, remove) |
| Swift `DJICameraSessionID`, `DJIControlEpoch`, `DJIConnectionRoute`; Kotlin `DJICameraSessionID`, `DJIControlEpoch` | app composition (the DJI integration's boundary names) |
| `MonitorUI` aliases of 15 `MonitorPresentation` values (`MonitorAssistTool`, `MonitorGridOption`, scope and false-colour values) and `MonitorPresentation.MonitorPreviewAdmission` | app composition (callers that import only `MonitorUI` keep compiling) |
| Android appkit `MonitorMediaLibraryModel` original constructor | retire (follow-up O-2) once no app calls it positionally |
| Saved-setup and preference migration: `LegacySavedCameraCodec`, `BodyRecordsV0`, `SavedCamerasStore.Legacy`, `MonitorOperatorPreferences.legacyKeepScreenAwake`, `MonitorMediaFavoriteAuthority.LEGACY_COMBINED` | brand wire format (saved setups and favorites survive upgrade) |
| Atlas registry: `repos/openinstacine/meta.json` live `source-copy` edges to OpenPocketCine and its stale `products`; the same claim in `atlas/README.md`, `repos/openinstacine/SUMMARY.md`, `docs/CONTRACTS.md`, `docs/PUBLISH.md` | retire (follow-up O-3) when `integration/thin-app` merges: the edges are still true for Insta `main`, and atlas facts change only after an authorized merge |

Retired here (`9fe3a9f`): the Kotlin aliases `MonitorZoomStops` (deprecated while adapters switched
to `MonitorZoomTapStops`) and `DjiConnectionRoute`, unused in OpenCine, in the three apps and at
their registered refs.

## OpenPocketCine

| Item | Verdict |
|---|---|
| `Package.swift` products `OpenPocketViewCore` (with `@_exported` OpenCineDJI, OpenCineMedia, OpenCineMotion, OpenCineRelay) and `OpenPocketCineAndroid` (`libOpenPocketCineAndroid.so`) | app composition; the library name is a brand wire format |
| `Sources/OpenPocketCineAndroidFacade`: `SwiftCoreJNI.swift` exports `Java_com_opencapture_openpocketcine_bridge_SwiftCore_*` (`coreVersion`, LUT packing, false-colour paint and weight, feed assist scalars), `FeedEffectsWire.swift`, `LUTLibraryWire.swift` | brand wire format; `FeedEffectsWire`'s false-colour lattice is main parity until a portable owner exists (follow-up P-3) |
| Android SharedPreferences names `openpocketcine.*`, iOS keychain services `com.opencapture.openpocketcine.*` and `OpenPocketCine.frameio`, legacy value migrations (keep-screen-awake, clip shot colours, LUT selection, feed upscaler raw values, `SavedCamerasStore.Legacy`) | brand wire format |
| iOS `CameraSession` composition and its projections (`sessionRecovery`, `legacyConnectionRunError`, `DjiAppleTransportHost.pocket`, `LiveAssistEngine`, `LiveLUTResolver`, inspector renderer init) | app composition or main parity |
| `AppRoot.liveOperatorPanel` (projects `shell.cover` for native panels) | app composition; follow-up P-6 when the panels read the shell cover directly |
| `Sources/OpenPocketViewCore` DJI twins with no Swift owner: `LiveChromeThrottle`, `GamepadOperator`, `SavedCamera` (`CameraConnectionSetup`, `CameraWifiResolution`, `FoundCameraIdentity`), `SessionRecoveryCopy` | main parity; follow-up P-2 (`ConnectionPhase` is now OpenCineCameraVocabulary's `CameraConnectionPhase`) |
| `PlaybackVideoLayout`, `GimbalStickLuma`, `ExposureMeterReading`, `CameraWiFiQRCode`, `PlaybackAudio.AudioLevelTapBox`, `rememberPlaybackMonitorGlass`, `GlassChrome`, `CameraMedia.cacheEntries` | main parity |
| Theme forwarders `BrandColors`, `OpcFonts`, `LiveType`, `LiveDesign` (brand tokens mixed with `MonitorPalette`/`MonitorTypography` pass-throughs) | app composition; pass-through members are follow-up P-1 |
| Typealias bridges to shared types: 191 on the union (Swift and Kotlin) | see "Retired here"; the remaining heavy aliases are follow-up P-1 |
| Tooling copied between the apps (`scripts/android-stage-swift-core.sh`, `checkout-opencine.sh`, release-note and tester-note scripts) | app composition; follow-up X-2 (parameterized copies in OpenCine `scripts/`) |
| Source sync | none: Pocket was the donor and never carried sync tooling |

Retired here (`2216acb5`, production about -1,500 lines net):

- Dead code: `ios/OpenPocketCine/FeedSuperResolution.swift` (694 lines, a copy of
  `MonitorSuperResolutionScaler` with no caller since `299fad83`), the facade's unused JSON helpers and
  its private copy of `javaFloatArray` (`OpenCineJNISupport` has the public one), Swift and Kotlin
  `PlaybackFrameTap`.
- JNI, both sides in step: exports `hevcCsd`, `hevcNalTypes`, `hevcIsKeyframe`, `validateImportedLut` and
  `conformPreviewJSON` with their `external fun`s and the helpers only they reached. `llvm-nm` of
  `libOpenPocketCineAndroid.so` lists exactly the six remaining `SwiftCore` exports; the 30
  `DjiNative` exports are unchanged.
- Copies and forwarders: the Android `ConformPreview` copy (callers use `MonitorConformPreview`; the
  file keeps `PlaybackVideoLayout`), the `NDFilterRecommendation` forwarder and its two aliases (the
  app passes its dash label to `MonitorNDFilterRecommendation`), 16 identity adapters in
  `OperatorSetup.kt`, `OperatorHaptics.kt`, `MonitorPageScaffold.kt`, `LiveTypeDesign`, the
  `AnamorphicDesqueeze` forwarders.
- Aliases: 94 of the 191 (no reference, test-only, used only in their own file, or same-name
  re-exports); six alias-only files deleted.
- Docs: `AGENTS.md`, `ANDROID.md`, `docs/ARCHITECTURE.md`, `docs/diagnostics.md`,
  `docs/feed-watchdog.md`, `docs/SHARED-MONITOR-ENGINE.md` and seven handbook protocol and device pages
  point at the current OpenCine owners.

## OpenInstaCine

| Item | Verdict |
|---|---|
| Source sync from OpenPocketCine (scripts, overlay helper, just recipe, stamp) | retired before this lane (`705d316`, `67c4250`); the iOS and Android shells are app-owned code on the shared shell, no longer synced |
| `docs/implementation/baseline-provenance.json`, attribution in NOTICE, THIRD-PARTY-NOTICES and `LegalScreens` ("adapted from OpenPocketCine") | stay (licence provenance and history) |
| `Package.swift` products `OpenPocketViewCore` and `OpenPocketCineAndroid`, Android package `com.opencapture.openpocketcine`, Gradle `openpocketcine.versionCode`/`versionName` | brand wire format and app composition; renaming is follow-up I-6 (release tooling, JNI names in step) |
| `Sources/OpenPocketCineAndroidFacade` live exports (`coreVersion`, LUT packing, false-colour paint and weight, feed assist scalars) | brand wire format |
| JNI exports `cameraSoftAPDecision` and `conformPreviewJSON` (no Kotlin production caller; an instrumented test uses them) | retire (follow-up I-5): remove both sides in step with the instrumented test |
| `Sources/OpenPocketViewCore`: forks of `OpenCineDJI` reached by the Luna build (`CameraControl` vocabulary, `CamCap` dial lists, `CameraStatus`, `MediaManifest`, `MonitorLUT`, `TrackingBox`, `SessionRecovery`, `ReconnectBackoff`, `FeedWatchdog.stallThreshold`, `CameraSoftAP` freshness helpers) | main parity; follow-up I-2 (a neutral camera vocabulary; drop the DJI wire parsers with it) |
| Byte copies of DJI owners that Luna reaches: `ExposureLock`, `FacePriorityExposure`, `GamepadOperator` (both platforms), `FaceDetectFlight`, `VirtualJoystickMapping`, `GimbalStickTouchMapping`, `CamFov` zoom stops, `PrivacyRedactor`, `CameraWifiCredentialStore` | main parity (redactor and credential store also brand wire format); follow-up I-3 (a neutral OpenCine owner used by both `dji` and Insta) |
| Reached but inert DJI behavior: convert-log (`LogColorTransform`), `ClipColorProfile`, D-Log live calibrations, Kotlin `ApertureStrategy`, the debug Pocket 4 Pro reconnect | main parity until a visible-behavior decision; follow-up I-7 |
| iOS `CameraSession` quartet and `CameraMedia`, Android `PocketCameraSession` | app composition and main parity; follow-up I-1 (ownership move into OpenCineAppKit / LunaCameraSession) |
| Pocket-derived code with no OpenCine owner (reliability reporting and Sentry sinks, live chrome and capture sheets, assists views, Frame.io and delivery views, gimbal and head-track UI, watcher views, pairing permissions) | main parity; Sentry sinks are SDK adapters; follow-up I-4 (move area by area into MonitorUI/monitor-ui, OpenCineAppKit/appkit, OpenCineApple, OpenCineRelayApple) |
| Multiview stubs and constant-false branches | retired in follow-up I-8 (Insta `24ff364`); the gimbal-limit pulse is live (Luna gimbal status field 92 and notification 8302 drive it) and stays |

Retired here (`32caba6`, production -1,905 lines net; the eight `SwiftCore` JNI exports are
unchanged and match their `external fun`s):

- DJI code the Luna build never reaches: `Commands.swift`, `DumlFrame.swift` and `CameraParam`, the empty
  `EncoderPresentPath+DJI` and `Hevc+DJI` extensions, `MultiviewRecovery` and the facade's unread
  watchdog and recovery stores, the `CamAudioStatus` parser, `CameraSoftAPSwitch`, `SharedWiFiPath` and
  all of `WiFiJoiner` except `leave(ssid:)`, the bundled Pocket and DJI LUT loaders (only the Luna cube
  ships), 106 unreferenced `CameraCommands.kt` members (DUML builders and constants), the multiview
  control lease and the never-passed `controlLease` and `borrowing` parameters, `multiviewAutoLut`,
  `SettingsHelpCopy.PROTOCOL`, `LiveLockButton`, `ScopeMonitorLook` with `ScopeSampler.monitorCube`.
- Forwarders and aliases: the `AudioLevelMeter` names (callers use `MonitorAudioMeterLevels`), the
  `NDFilterRecommendation` forwarder (the dash label is passed explicitly), three motion forwarders, the
  two-argument `WatcherRelayJoin.hostAccepts`, the `LUTLibraryWire` import validation reached by no
  export, the Frame.io alias files, `MonitorPageScaffold`, the dead and small iOS aliases and 54 Kotlin
  aliases.
- Source-sync leftovers: the `openpocketcine-provenance.json` stamp, `tools/analyze-live-log.py` and
  `tools/pull-control-log.sh` (Pocket copies; the latter pulled Pocket's container), the Gradle input
  for the missing `Adapters/OsmoCompatibility`, duplicate `ios/project.yml` keys.
- Docs: `README.md`, `docs/DEVELOPMENT.md`, `docs/implementation/` (architecture, OpenCine integration,
  Apple session and adapter review, Luna iOS status, shared-core extraction), the handbook app and
  device pages and `.github/labels.yml` describe app-owned shells on the shared OpenCine shell, no longer
  synced from OpenPocketCine (I-6 documentation clause). Dated history entries stay as history.

Still to do from the same sweep: 12 Kotlin aliases that instrumented tests use and
`FalseColorReferencePositions` (used by the UI review host) wait for their test owners.

## OpenZCine

| Item | Verdict |
|---|---|
| Monitor slots | no whole-screen slot remains: iOS `NikonMonitorShell` and Android `MonitorScreen` mount the shared monitor through bounded slots; the Android `MonitorShell` placeholder is retired (Pocket mounts its monitor with no core gate) |
| Compatibility projection | none: the panels read the shared control model's pending targets at read time (iOS) and the shared `MonitorFieldLayout` directly (Android); retired by the nikon-z1 lane |
| Native runtime | no duplicate: the app ships no shader, SPIR-V or native code and loads OpenCine's assets; `scripts/check-gles-shaders.sh` lints the OpenCine copy (follow-up X-1: move it into OpenCine `scripts/`) |
| Test-only frozen donors (`:frozen-vulkan-donor`, `FrozenNikon*`, parity tests, about 4,700 lines) | stay until the Z-3 parity checkpoint closes |
| `Sources/OpenZCineAndroidFacade` (25 exports `Java_com_opencapture_openzcine_bridge_SwiftCore_*`, Frame.io, LUT, scope, playback-audio and feed-effects wires), `AndroidLiveViewPolicyWire` | brand wire format; the dead export `feedEffectsScalars` and the ignored policy parameters are follow-up Z-4 (both sides in step) |
| Monitor relay (`_openzcine-mon._tcp`, version 2, JPEG and HEVC), watch wire (`WatchRelayProtocolV1.json` with the Wear twin), Kotlin `core-api` relay types | brand wire format; converging on OpenCineRelay/OpenCineWatch is follow-up Z-5 |
| Saved keys and credentials (`NativeCameraConnectionStore` rebrand migration, `CameraWiFiCredentialStore`, assist and scope storage keys) | brand wire format |
| Discovery: `NativeCameraDiscovery`, `InfrastructureCameraFinder` (iOS), Kotlin discovery adapters | SDK adapter and Nikon feature (passive discovery); follow-up Z-6 (an Apple Nikon integration target) |
| Android `diagnostics/SentryReliabilitySink.kt` and `OkHttpManualReportUpload.kt` (Pocket's two files with only the package changed; Insta carries the same copy), with Pocket's `sentry-android` and `okhttp` versions | SDK adapter: OpenCine takes no third-party package, so the Sentry and OkHttp adapters stay per app |
| Android diagnostics journal: `DiagnosticEventStore` (closed event vocabulary; `events.log` and `connect-trace.log` formats), the share report renderer and the historical exit reader | Nikon feature and saved data: only closed codes reach a report, and no shared owner keeps a closed vocabulary or these files (OpenCine `DiagnosticJournal` is a free-form in-memory ring). The problem-report text already goes through the shared `BoundedDiagnosticFormatter`, `ManualProblemReport` and incident runtime; Nikon iOS keeps its journal too |
| Nikon calibration and policy (`ExposureScale`, `FalseColor`, `FocusAssist`, `TrafficLightsMeter`, `MonitorLUT`, RED LUTs, `ThermalLoadPolicy`, `MonitorChrome` DISP modes, MF drive, photography) | Nikon feature |
| Kept app copies of shared owners: `OpenZCineCore.MonitorAssistTool` (the shared enum lacks PLAY and MAG, titles differ, not `Codable`), the horizon line (Nikon feature, no shared equivalent; the level gauge is the shared `MonitorLevelOverlay`), `MovablePanel` for the audio and false-colour panels (the shared panel always draws a resize grip; Android draws both on the shared `MonitorMovableScopePanel` with the shared ruler and meter), Android `FrameRateSampler` (reads READY where the shared one reads 0.00), Android `SelectionHeader` (small gain), glass chrome (different rendering technology), Android media browser composition (header, selection header, filter dialog, storage-slot cards and portrait band already sit on the monitor-ui page owners; camera-controls `MediaLibraryPage` would need six parameters and leave 15 of its 18 actions as no-ops; Nikon iOS keeps its browser composition too), still-viewer and live-feed pinch zoom on both platforms (`MonitorPlaybackZoom` resets its pan baseline when either gesture ends, so a pinch that ends mid-drag jumps; the Android live feed also zooms to 8x), Android playback audio meter ballistics (stepped through the Swift JNI wire with the same constants as `MonitorAudioMeterBallistics`), the Android Frame.io account row (its switching-networks state, sign-in over internet, retry and error line would need four more parameters on monitor-ui `MonitorAccountSettings`) | Nikon feature or follow-up Z-2, reason per item |
| Android Operator Settings composition (`OperatorSettingsScreen`; its cards already sit on the monitor-ui settings owners, the card resets on appkit `MonitorAssistState.resetSettings`) | follow-up Z-7: camera-controls `OperatorSetupScreen` would need about 20 parameters and whole-tab replacements; Display needs DISP 3 and a capture side that appkit `MonitorDisplayMode` and `chrome()` lack; Storage keeps Nikon's purge result |
| `RelayBitrateAdaptation`, `RelayControlLease` | follow-up Z-5 (iOS has no OpenCineRelay link, Kotlin no shared owner) |
| Android media owners: two `MediaCacheStore` instances, the share intent, the listing checkpoint | follow-up Z-3: one cache instance changes transfer reader/writer wake-up (needs a hardware run); the shared share API would grow; the checkpoint's census tests are its only unit coverage, so they move to the shared codec first |
| Source sync | none |

Retired here (`fbbbd705`, `4f11941d`, `5c8bda63`, production -364 lines net):

- iOS: the `LiveFeedNoiseFilter`, `PlaybackAudioMeterController` and `ConformPreview` aliases, the
  `CubeLUTParseError` re-export, the legacy `MediaLUT.export(baseName:)` overload and four
  `MonitorMovieFile` forwarders, `MetalFeedFrameBaker` and `LiveFrameRenderer` forwarders,
  `FrameSampling`, the `FeedUpscaler` super-resolution copies, the `OperatorSettingsTab` alias, the
  app copy of `PortraitFeedAspect` (now re-exported from OpenCineMedia: same cases, raw values and
  `Codable`), and the `Magnification` enum of the retired MAG tool (its one call always returned
  `false`; the saved magnification setting stays).
- Android: `VulkanLiveFeedNative` (not a JNI class), unused `ZoneStyle` constants, the deprecated
  `fromFailurePhase`, `drainPeaks`, the `FrameioLutPayload`, `MediaExportContainer` and
  `LiveFramePreviewBaker` aliases, `FramePacing.kt`, the `MediaClips` forwarder.
- Tooling: `scripts/check-vulkan-shaders.sh` (the recipe calls OpenCine's script directly).
- Tests: `Tests/OpenZCineCoreTests/MediaFilterDerivationTests.swift`, the same 18 cases as OpenCine's
  `NikonMediaFilterDerivationTests` run through the app's legacy alias names.

Retired by the nikon-z1 lane (OpenZCine `8bef53c3`, `9010d9d2`, `5e175fa8`, `82acde96`, `d41a253f`; OpenCine `6dd6dd4`):

- Z-1, iOS: `makeShellModel`'s write-back of the control's pending edits and reported recording into
  `CameraDisplayState`; the command grid, side column, values bar and picker read the pending target
  over the report (`NativeAppModel.shownCameraValues`). Recording stays camera-authoritative.
- Z-1, Android: `bridge/MonitorZones.kt` (`MonitorZones`, `ZoneStyle`, `ZoneFrame`); its consumers take
  `MonitorFieldLayout` and `MonitorRect`. The `MonitorShell` placeholder and its core gate; the three scope
  helpers that called the core unguarded now fail closed like every other core call.
- Z-7: `AnchoredPinchZoom` (the shared `MonitorPlaybackZoom`'s unbounded API line for line) and the Android
  `JpegFrameDecoder` forwarder (callers pass the Nikon 1024 cap to `MonitorJpegFrameDecoder`).
- Z-2 (part): the `FrameRateSampler` re-export, the `FrameScopeSampler` wrapper of
  `MonitorUIImageScopeSampler`, and Android `AndroidBatteryReadout` (appkit's `rememberPhoneBatteryReadout`;
  its mapping test moved to `PhoneBatteryReadoutTest`).

Retired by the nikon-z1 lane, round 2 (OpenZCine `1313f77f`, `5cf86817`, `ec3381b7`, `f6135ef1`, `9b0afd04`,
`b6a60447`, `47ce0974`, `e63a37d4`; OpenCine `b874e0b`, `75217b2`; OpenPocketCine `9325d8b3`; OpenInstaCine `cee4769`):

- Z-2, aliases: every app alias over a shared type (Swift media filter names, `StreamPreset` and
  `QualityBias`, the audio meter aliases, `StoredLUT`; Kotlin settings, effects, Frame.io and media
  aliases). The meter and stored-LUT types are re-exported from OpenZCineCore (`@_exported import`), so
  the Watch app and the JNI facade keep one import; raw values, `Codable` keys and wire bytes are unchanged.
- Z-2, owners: `FeedUpscaler` (`MonitorUpscaler`), `StoredLUT` and the folder index (`StoredCustomLUT`,
  `CustomLUTIndex`), `SettingsDashScale` (`MonitorLinkHealthScale`), `GlassChoice`, the Android
  `MonitorPickerAnchor` and the gallery album path (`MediaStoreInsertPolicy`).
- Z-3, iOS: `MediaBrowserView` renders the shared `MonitorMediaCatalog`. Nikon keeps its media features
  through additive slots with empty defaults (card-slot cards in the landscape sidebar, the caching bar
  under the header, burst count, RAW+J, EXPORTED and caching badges on `MonitorMediaItem`); opening,
  sharing, caching and deleting stay Nikon's. Pocket and Insta use the shared `MonitorCatalogFilterButton`
  (their identical copies are gone) and render pixel-identically. `MonitorCatalogHeader` and the
  app-hosted `MonitorMediaSelectionHost` lost their only caller and are removed from OpenCine.
- Tests: Nikon's `AudioLevelMeterTests.swift` (its three missing cases moved into
  `MonitorAudioMeterBallisticsTests`) and two LUT tests duplicated by OpenCine `CubeLUTTests`.

## Follow-ups

| Id | Repository | Item | Blocked by |
|---|---|---|---|
| O-1 | OpenCine, Pocket | Rename the Pocket-named DJI session types | add, migrate, remove across a release |
| O-2 | OpenCine | `MonitorMediaLibraryModel` original constructor | apps calling it positionally |
| O-3 | OpenCine | Atlas Insta `source-copy` edges, products and docs | the authorized merge of `integration/thin-app` |
| P-1 | Pocket | Heavy alias and theme pass-through renames (`LiveAssistTool` 213 sites, `OpcIcon` 158, `ChromeRect` 80, `PocketDispSection` 72, iOS `LiveImageEffects`, `FalseColorScaleKind`, `FoundCamera`) and the 62 lighter alias renames | churn across files other lanes edit |
| P-2 | Pocket, Insta | Swift owners in OpenCineCameraVocabulary for the view-core twins (`CameraConnectionPhase`, `LiveViewLink`, `LiveFeedWarmup` moved; each view core keeps `ConnectionPhase` as a typealias); `WatchRelayState.snapshot` stays per app (the vocabulary takes no relay edge; only its wrist copy differs) | new shared owner |
| P-3 | Pocket, Insta, Nikon | Portable false-colour lattice in OpenCineMedia | new shared owner |
| P-4 | Pocket | Tracking-bracket geometry, number-pad input, playback pan, media path helpers, Kotlin `ClipColorProfile`, iOS reliability reporting, `FeedIncidentQueue` glue, `MediaSessionLink` | expose or extend shared owners |
| P-5 | Pocket | `InspectorPreviewRenderer.kt` factory (used by an instrumented test) | an instrumented run |
| P-6 | Pocket | `AppRoot.liveOperatorPanel` projection | shell cover API |
| I-1 | Insta | `CameraSession` ownership into OpenCineAppKit / LunaCameraSession | I-6 session work |
| I-2 | Insta | Neutral camera vocabulary; drop DJI wire parsers | new shared owner |
| I-3 | Insta, OpenCine | Neutral owner for the reached DJI copies | new shared owner |
| I-4 | Insta | Pocket-derived areas into OpenCine | per-area moves |
| I-5 | Insta | Dead JNI exports `cameraSoftAPDecision`, `conformPreviewJSON` | an instrumented run |
| I-6 | Insta | Brand renames (`openpocketcine.version*`, `PocketCameraSession`, module and package names) | release tooling, JNI names in step |
| I-7 | Insta | Inert DJI behavior on reached paths | visible-behavior decision |
| Z-2 | Nikon | Kept app copies of shared owners | the reason named per item in the OpenZCine table |
| Z-3 | Nikon | Android media owners | a hardware run for one cache instance; shared share API; census tests on the codec |
| Z-4 | Nikon | `feedEffectsScalars`, ignored policy parameters | JNI export gate |
| Z-5 | Nikon | Relay and watch wire convergence | wire version decision |
| Z-6 | Nikon | Discovery into an Apple Nikon integration target | hardware-qualified reason |
| Z-7 | Nikon | Android Operator Settings onto camera-controls `OperatorSetupScreen` | camera-controls moving its Assist and Display tabs onto the monitor-ui owners Nikon already uses (`MonitorViewAssistSettings`, `MonitorDisplaySettings`) |
| X-1 | Nikon, OpenCine | `check-gles-shaders.sh` into OpenCine | none |
| X-2 | all apps | Shared release and staging scripts | new shared tooling |
| X-3 | Pocket, Insta | Stale references found while retiring: Pocket `tools/performance-status-probe.sh` calls `AndroidSessionWire.statusJSON`, which no longer exists; three links in Pocket `docs/audits/*.md` point at moved view-core files; Insta `docs/implementation/architecture.md` and the handbook `protocol/ucd2-frame.md` name the moved `Adapters/Insta360Protocol` | docs and tooling refresh |
