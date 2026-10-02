# Graph Report - openinstacine@31d3a3c274c9  (2026-10-02)

## Atlas provenance
- Source: `openinstacine@31d3a3c274c9ea998cf450fd2b7cee749c5a8d6b` (ref `opencine/integration`, candidate)
- Exact provenance, exclusions and coverage: `snapshot.json` beside this report.
- Navigation aid only. Dependency facts come from `atlas deps` and `atlas impact`.

## Corpus Check
- 913 files · ~915,312 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 18918 nodes · 46328 edges · 721 communities (635 shown, 86 thin omitted)
- Extraction: 93% EXTRACTED · 7% INFERRED · 0% AMBIGUOUS · INFERRED: 3403 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- Sendable
- PocketCameraSession
- OpenPocketViewCore
- HevcDecoder
- Duml
- CameraStatus
- SwiftUI
- PlaybackFeedSession
- String
- CameraSession
- FrameioService
- DatalinkDriver
- Double
- FeedStressTests
- View
- LiveScopes.swift
- CameraSession
- GimbalWaypoint
- ChromeRect
- .chrome
- ColorMode
- BackdropRenderActivity
- XCTest
- AppModel
- .line
- FeedStressRuntime
- .encode
- LiveAssistState
- CaptureSheet
- Double
- GimbalGamepadDriver
- StationNetworkSetup.kt
- CamCapTests
- CameraControl.swift
- XCTestCase
- LunaLiveWalkthroughTests
- LogColorTransform
- SettingsRootView
- CameraSoftAP
- NSObject
- ... 675 more in graphify_labels.json

## God Nodes (most connected - your core abstractions)
1. `OpenPocketViewCore` - 239 edges
2. `Data` - 217 edges
3. `PocketCameraSession` - 191 edges
4. `Foundation` - 173 edges
5. `Duml` - 159 edges
6. `CameraStatus` - 135 edges
7. `CameraStatus` - 129 edges
8. `GimbalProgram` - 126 edges
9. `CameraSession` - 122 edges
10. `SwiftUI` - 121 edges

## Surprising Connections (you probably didn't know these)
- `BrandColors` --references--> `Color`  [EXTRACTED]
  Apps/Android/monitor/src/main/kotlin/com/opencapture/openpocketcine/Theme.kt → ios/OpenInstaCine/Assists/PeakingAssist.swift
- `Tile` --calls--> `GimbalStickMapping`  [INFERRED]
  ios/OpenInstaCine/MultiviewSession.swift → Sources/OpenPocketViewCore/CameraControl.swift
- `LunaShellMapping` --calls--> `CameraModel`  [INFERRED]
  ios/OpenInstaCine/LunaShellMapping.swift → Sources/OpenPocketViewCore/CameraModel.swift
- `LunaShellMapping` --calls--> `CameraProfile`  [INFERRED]
  ios/OpenInstaCine/LunaShellMapping.swift → Sources/OpenPocketViewCore/CameraProfile.swift
- `ChaosExperiment` --calls--> `CameraSetMailbox`  [INFERRED]
  Tests/OpenPocketViewCoreTests/ConnectionChaosTests.swift → Sources/OpenPocketViewCore/CameraSetMailbox.swift

## Import Cycles
- None detected.

## Knowledge Gaps
- **1882 isolated node(s):** `LunaCameraLooks`, `SETTINGS`, `MEDIA`, `PRIVACY`, `TERMS` (+1877 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **86 thin communities (<3 nodes) omitted from report** - run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Unit` connect `Unit` to `Sendable`, `BleLink`, `PocketCameraSession`, `DatalinkDriver.kt`, `String`, `DiagnosticJournal`, `ChromeRect`, `AssistGeometry.kt`, `StationNetworkSetup.kt`, `LiveFaceDetector`, `.capturePayload`, `SettingsInlineRow`, `AssistToolGlyph`, `LiveZoomChip`, `MediaCatalogClip`, `MultiviewNetwork.kt`, `MultiviewSession`, `GpuOverlayBus`, `MonitorCameraValues`, `MonitorPageScaffold`, `MediaDeliveryPopup.kt`, `CaseIterable`, `Options`, `MediaLibraryController`, `RoundedCornerShape`, `SavedCamera`, `LUTPickerBody`, `MediaSessionLink`, `ReliabilityReporting`, `ScopePanels.kt`, `LiveControlSheetContent`, `LiveViewScreen`, `detectPanelDrag`, `CallbackOperationOwner`, `TelemetryGauge`, `DiagnosticCenter`, `pairingPresentation`, `.launch`, `CameraApJoiner`, `HevcDecoder`?**
  _High betweenness centrality (0.219) - this node is a cross-community bridge._
- **Why does `GimbalProgram` connect `GimbalProgram` to `PocketCameraSession`, `DatalinkDriver`, `Rect`, `MotionControlInteractionTest`, `GimbalWaypoint`, `CameraSession`, `.point`, `LunaGimbalAimTest`, `GimbalPauseTest`, `Camera`, `Camera`, `.simulate`, `GimbalProgramCurveTests`, `LunaGimbalAim`, `.run`, `DumlFrame`, `GimbalZoomPath`, `GimbalPauseTests`, `GimbalWaypoint`, `GimbalProgramZoom`, `GimbalMoveEngine`, `Box`, `GimbalZoomPath`?**
  _High betweenness centrality (0.075) - this node is a cross-community bridge._
- **Why does `Color` connect `Color` to `Sendable`, `SwiftUI`, `String`, `.configure`, `MultiviewScreen.kt`, `View`, `LiveScopes.swift`, `ChromeRect`, `.chrome`, `ViewModifier`, `StationNetworkSetup.kt`, `RoundedRectangle`, `LiveGimbalStick`, `SettingsRootView`, `drawFocusBox`, `.playbackTransportBar`, `StationNetworkSetupView`, `SettingsInlineRow`, `AssistToolGlyph`, `TrafficLightsAssist`, `MonitorPresentationVisibilityTests.swift`, `LiveTopMenu`, `CaseIterable`, `ChromeEditorReturnTests`, `FieldMonitorStatusChrome`, `RoundedCornerShape`, `MediaLibraryScreen`, `Coordinator`, `ScopePanels.kt`, `LivePortraitChrome`, `MultiviewView`, `LiveLevelOverlay`, `OpcIcon`, `TelemetryGauge`, `LiveAssists.swift`, `.makeSession`, `.testTappedISOWhiteBalanceAndFocusKeepFullDetailsWhileHoldIsCompact`, `FalseColorReference`, `StartupChrome.swift`, `.launch`, `MediaChrome.kt`, `DesignShared.swift`?**
  _High betweenness centrality (0.067) - this node is a cross-community bridge._
- **What connects `LunaCameraLooks`, `SETTINGS`, `MEDIA` to the rest of the system?**
  _1918 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Sendable` be split into smaller, more focused modules?**
  _Cohesion score 0.03314379769564567 - nodes in this community are weakly interconnected._
- **Should `PocketCameraSession` be split into smaller, more focused modules?**
  _Cohesion score 0.02679011129715355 - nodes in this community are weakly interconnected._
- **Should `OpenPocketViewCore` be split into smaller, more focused modules?**
  _Cohesion score 0.03227132579650565 - nodes in this community are weakly interconnected._
