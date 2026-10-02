# Graph Report - openzcine@1b5d2cc1750a  (2026-10-02)

## Atlas provenance
- Source: `openzcine@1b5d2cc1750a69cb11719d0d1ca80ac7b3350cd1` (ref `opencine/integration`, candidate)
- Exact provenance, exclusions and coverage: `snapshot.json` beside this report.
- Navigation aid only. Dependency facts come from `atlas deps` and `atlas impact`.

## Corpus Check
- 747 files · ~1,148,334 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 16294 nodes · 40789 edges · 600 communities (514 shown, 86 thin omitted)
- Extraction: 91% EXTRACTED · 9% INFERRED · 0% AMBIGUOUS · INFERRED: 3506 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- OperatorSettings
- NativeAppRoot.swift
- OperatorPreferencesTests.swift
- BugReportFormModel
- MonitorPanels.swift
- AssistConfiguration
- NativeCameraSession
- AssistTool
- Sendable
- ScopeView.kt
- Text
- MediaBrowseScreen.kt
- MediaLUT
- OperatorPreferences.swift
- ZoneFrame
- CameraControl
- OpenZCineCore
- String
- MediaLibraryIndex
- ProgressivePlayer
- MonitorExperience.swift
- StoredLutLibrary
- OperatorSettingsScreen.kt
- String
- View
- MonitorScreen
- Identifiable
- FrameioDeliveryArtifact
- ExposureSignalMapping
- CodingKeys
- CameraSessionState
- Codable
- MediaCacheStore
- PlaybackAssistOptions.kt
- MediaFilterDerivationTests.swift
- FakeZRServer
- Long
- CameraApJoiner
- Coordinator
- MonitorRelayHost
- ... 549 more in graphify_labels.json

## God Nodes (most connected - your core abstractions)
1. `Text` - 215 edges
2. `FakeZRServer` - 179 edges
3. `OperatorSettings` - 173 edges
4. `PTPIPClientSession` - 173 edges
5. `Box` - 154 edges
6. `MonitorScreen()` - 147 edges
7. `chromeStyle()` - 143 edges
8. `OpenZCineCore` - 125 edges
9. `NativeCameraSession` - 118 edges
10. `ExposureSignalMapping` - 115 edges

## Surprising Connections (you probably didn't know these)
- `audioMeterLevelsMapCameraSegmentsOntoTheDBFSScale()` --calls--> `AudioMeterLevels`  [INFERRED]
  Tests/OpenZCineCoreTests/LiveViewFrameTests.swift → Sources/OpenZCineCore/AudioLevelMeter.swift
- `BrandColors` --calls--> `Color`  [INFERRED]
  ios/Runner/Branding.swift → Sources/OpenZCineCore/FocusAssist.swift
- `StartupColors` --references--> `Color`  [EXTRACTED]
  Apps/Android/app/src/main/kotlin/com/opencapture/openzcine/pairing/StartupDesign.kt → Sources/OpenZCineCore/FocusAssist.swift
- `applyRelayFrameReadings()` --calls--> `AudioMeterLevels`  [INFERRED]
  ios/Runner/NativeAppRoot.swift → Sources/OpenZCineCore/AudioLevelMeter.swift
- `contributedLookAt33IsTheContributorsOwnSamples()` --references--> `CubeLUT`  [INFERRED]
  Tests/OpenZCineCoreTests/MonitorLUTTests.swift → Sources/OpenZCineCore/CubeLUT.swift

## Import Cycles
- None detected.

## Knowledge Gaps
- **2574 isolated node(s):** `file-protection.sh script`, `post-swift-edit.sh script`, `session-start.sh script`, `npx`, `INCREMENTAL_BUILDS_ENABLED` (+2569 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **86 thin communities (<3 nodes) omitted from report** - run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Unit` connect `Unit` to `ConnectionProgressPopup.kt`, `OperatorSettings`, `Int`, `StepCard`, `AssistTool`, `Sendable`, `ScopeView.kt`, `Text`, `LiveFeedView`, `OperatorPreferences.swift`, `ProgressivePlayer`, `StartupHeader`, `RedLutDownloadScreen.kt`, `OperatorSettingsScreen.kt`, `.decodeToJpeg`, `String`, `MonitorScreen`, `CameraSession`, `CameraSessionState`, `Codable`, `PlaybackAssistOptions.kt`, `MonitorRelayHost`, `Color`, `PairingExperience.kt`, `FeedEffectsRenderPlan`, `CleanScopeProcessor`, `NikonOpenCineSession`, `.run`, `AndroidMediaRemoteShutter`, `CaseIterable`, `FakeBridge`, `MFDriveController`, `SavedCamerasExperience`, `LoopbackRelayHost`, `FakeSession`?**
  _High betweenness centrality (0.303) - this node is a cross-community bridge._
- **Why does `MonitorScreen()` connect `MonitorScreen` to `OperatorSettings`, `LocalFramingAssistOverlay`, `GlassTierTest`, `AssistTool`, `FocusFeedGesturesTest`, `ScopeView.kt`, `Text`, `LiveFeedView`, `ZoneFrame`, `CameraControl`, `CameraSession`, `AndroidWearPhoneRelay`, `CameraSessionState`, `PlaybackAssistOptions.kt`, `MonitorRelayWire`, `.key`, `.onCreate`, `CameraPropertySnapshot`, `TestSharedPreferences`, `Unit`, `Color`, `feedTextureVisibleRect`, `FocusSession`, `AudioMetersOverlay`, `LiveOverlayRect`, `MonitorCameraStatus.kt`, `NikonOpenCineSession`, `FocusFeedGestures.kt`, `InstantReviewController`, `PhotographyChrome.kt`, `LiveViewGuideOverlay`, `AndroidThermalTier`, `FeedZoomTest`, `.run`, `PhotographyPickersTest`, `AndroidMediaRemoteShutter`, `FakeBridge`, `LiveFrame`, `MFDriveController`, `FakeSession`, `FakeCameraSession`, `AndroidLinkHealthMonitor`?**
  _High betweenness centrality (0.082) - this node is a cross-community bridge._
- **Why does `Text` connect `Text` to `ConnectionProgressPopup.kt`, `OperatorSettings`, `LocalFramingAssistOverlay`, `FrameioDeliveryDialog`, `StepCard`, `MonitorPanels.swift`, `RoundedRectangle`, `AssistTool`, `BugReportFormModel`, `ScopeView.kt`, `MediaBrowseScreen.kt`, `CameraControl`, `ProgressivePlayer`, `StartupHeader`, `RedLutDownloadScreen.kt`, `OperatorSettingsScreen.kt`, `MonitorScreen`, `CameraSessionState`, `PlaybackAssistOptions.kt`, `.onCreate`, `WearMonitorScreen.kt`, `CameraWifiScanner.kt`, `Unit`, `Color`, `PairingExperience.kt`, `LiveOverlayRect`, `WhiteBalanceTintPad`, `MonitorCameraStatus.kt`, `.portraitShell`, `InstantReviewController`, `OperatorSettingsPanel`, `PhotographyPickersTest`, `OpenZCineTheme`, `SavedCamerasExperience`?**
  _High betweenness centrality (0.074) - this node is a cross-community bridge._
- **Are the 193 inferred relationships involving `Text` (e.g. with `AssistToolCell()` and `CommandControlDialog()`) actually correct?**
  _`Text` has 193 INFERRED edges - model-reasoned connections that need verification._
- **What connects `file-protection.sh script`, `post-swift-edit.sh script`, `session-start.sh script` to the rest of the system?**
  _2574 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `OperatorSettings` be split into smaller, more focused modules?**
  _Cohesion score 0.017155894870782326 - nodes in this community are weakly interconnected._
- **Should `NativeAppRoot.swift` be split into smaller, more focused modules?**
  _Cohesion score 0.022166395744052016 - nodes in this community are weakly interconnected._
