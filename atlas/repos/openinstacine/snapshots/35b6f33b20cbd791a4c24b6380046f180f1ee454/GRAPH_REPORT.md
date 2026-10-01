# Graph Report - openinstacine@35b6f33b20cb  (2026-10-01)

## Atlas provenance
- Source: `openinstacine@35b6f33b20cbd791a4c24b6380046f180f1ee454` (ref `main`, baseline)
- Exact provenance, exclusions and coverage: `snapshot.json` beside this report.
- Navigation aid only. Dependency facts come from `atlas deps` and `atlas impact`.

## Corpus Check
- 1158 files · ~1,097,745 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 23647 nodes · 57503 edges · 907 communities (806 shown, 101 thin omitted)
- Extraction: 92% EXTRACTED · 8% INFERRED · 0% AMBIGUOUS · INFERRED: 4630 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- Sendable
- PocketCameraSession
- OpcVk
- SwiftUI
- HevcDecoder
- LiveChrome.kt
- Duml
- FrameioService
- Foundation
- ChromeRect
- CameraStatus
- DatalinkDriver
- PlaybackFeedSession
- FeedWatchdog
- Color
- CameraControl.swift
- CameraSoftAP
- LiveScopes.swift
- AppModel
- FeedStressTests
- CameraSession
- String
- CaptureSheet
- View
- Double
- CaseIterable
- XCTest
- Text
- .line
- UInt8
- CameraSession
- MonitorIcon
- FeedStressRuntime
- LutCatalog
- AssistRect
- MonitorIcon
- AndroidSessionWire
- Double
- .chrome
- UCD2Message
- ... 856 more in graphify_labels.json

## God Nodes (most connected - your core abstractions)
1. `Foundation` - 249 edges
2. `OpenPocketViewCore` - 247 edges
3. `OpcVk` - 226 edges
4. `PocketCameraSession` - 181 edges
5. `Duml` - 159 edges
6. `SwiftUI` - 156 edges
7. `Color` - 152 edges
8. `CameraStatus` - 135 edges
9. `CameraStatus` - 126 edges
10. `CameraSession` - 118 edges

## Surprising Connections (you probably didn't know these)
- `CameraSession` --calls--> `LunaGimbalPoseEstimator`  [INFERRED]
  ios/OpenInstaCine/CameraSession.swift → Adapters/Insta360Protocol/Sources/Insta360Protocol/LunaGimbalPose.swift
- `runSet()` --calls--> `LunaPhotographyType`  [INFERRED]
  tools/LunaProbe/Sources/LunaProbe/main.swift → Adapters/Insta360Protocol/Sources/Insta360Protocol/LunaProtocol.swift
- `run()` --calls--> `LunaRequest`  [INFERRED]
  tools/LunaProbe/Sources/LunaProbe/main.swift → Adapters/Insta360Protocol/Sources/Insta360Protocol/LunaProtocol.swift
- `Camera` --calls--> `LunaRequestCounter`  [INFERRED]
  tools/LunaProbe/Sources/LunaProbe/Camera.swift → Adapters/Insta360Protocol/Sources/Insta360Protocol/LunaProtocol.swift
- `LunaVideoResolution` --calls--> `result`  [INFERRED]
  Adapters/Insta360Protocol/Sources/Insta360Protocol/LunaStatus.swift → Sources/OpenPocketViewCore/WatchRelayProtocol.swift

## Import Cycles
- None detected.

## Knowledge Gaps
- **2744 isolated node(s):** `timelapse`, `normalImage`, `normalVideo`, `timeShift`, `slowMotion` (+2739 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **101 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Unit` connect `Unit` to `Sendable`, `SharedWiFi`, `StationNetworkSetup.kt`, `PocketCameraSession`, `LiveChrome.kt`, `AppModel`, `DiagnosticCenter`, `MediaSessionLink`, `.launch`, `String`, `CameraApJoiner`, `CaseIterable`, `Text`, `AssistRect`, `CallbackOperationOwner`, `MultiviewTileChrome`, `MonitorQuickInteraction`, `BleLink`, `LunaBackend`, `LunaChannel`, `DatalinkDriver.kt`, `MultiviewSession`, `ReliabilityReportingConsent`, `MediaCatalogClip`, `MonitorCameraValues`, `LiveFaceDetector`, `MonitorCameraCard`, `OpcIcon`, `detectPanelDrag`, `Box`, `DiagnosticJournal`, `MediaLibraryController`, `LiveControlSheetContent`, `LiveZoomChip`, `ReliabilityReporting`, `HevcDecoder`, `SettingsRowCard`, `Canvas`, `Identifiable`, `ZebraAssistTests`, `LUTPickerBody`?**
  _High betweenness centrality (0.284) - this node is a cross-community bridge._
- **Why does `PocketCameraSession` connect `PocketCameraSession` to `CameraControls`, `CameraSession.kt`, `PocketCameraSession.kt`, `Job`, `LiveZoomChip`, `DiagnosticCenter`, `pin`, `MotionProgramSessionTest`, `FeedSuperResolutionScaler`, `Unit`, `DumlFrame`, `CameraGimbalAngle`, `SessionRecovery.kt`, `Boolean`?**
  _High betweenness centrality (0.056) - this node is a cross-community bridge._
- **Why does `Color` connect `Color` to `MediaLibraryScreen`, `Sendable`, `StationNetworkSetup.kt`, `AudioMetersPanelMini`, `Band`, `LiveChrome.kt`, `LiveColorScienceTests`, `SwiftUI`, `ChromeEditChrome.swift`, `ViewModifier`, `LiveGimbalStick`, `StartupChrome.swift`, `.testTappedISOWhiteBalanceAndFocusKeepFullDetailsWhileHoldIsCompact`, `MonitorMediaFilterForm`, `LiveScopes.swift`, `.launch`, `String`, `View`, `CaseIterable`, `Text`, `MonitorIcon`, `LiveLevelOverlay`, `MonitorPresentationVisibilityTests.swift`, `MultiviewTileChrome`, `.chrome`, `MonitorGlassSurface`, `MonitorAssistIcon`, `MonitorCaptureTabRow`, `MultiviewScreen.kt`, `MonitorZoomDial`, `.draw`, `SettingsRootView`, `FalseColorReference`, `MonitorLevelGauge`, `LiveAssists.swift`, `.configure`, `StationNetworkSetupView`, `MultiviewView`, `MediaPlayerScreen`, `MediaPlayerView`, `.display`, `MonitorCameraCard`, `OpcIcon`, `MonitorAssistPalette`, `Sensitivity`, `LiveTopMenu`, `TrafficLightsAssist`, `SettingsRowCard`, `Identifiable`, `Canvas`, `FieldMonitorStatusChrome`, `LiveFocusTrackingLayer`, `MonitorControlGrid`?**
  _High betweenness centrality (0.047) - this node is a cross-community bridge._
- **What connects `timelapse`, `normalImage`, `normalVideo` to the rest of the system?**
  _2780 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Sendable` be split into smaller, more focused modules?**
  _Cohesion score 0.024723618090452263 - nodes in this community are weakly interconnected._
- **Should `PocketCameraSession` be split into smaller, more focused modules?**
  _Cohesion score 0.02555677254472435 - nodes in this community are weakly interconnected._
- **Should `OpcVk` be split into smaller, more focused modules?**
  _Cohesion score 0.012345679012345678 - nodes in this community are weakly interconnected._
