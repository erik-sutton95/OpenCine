# Graph Report - openpocketcine@27b15028e86d  (2026-10-01)

## Atlas provenance
- Source: `openpocketcine@27b15028e86d93798c802ddb56c7c474a30bb4c7` (ref `main`, baseline)
- Exact provenance, exclusions and coverage: `snapshot.json` beside this report.
- Navigation aid only. Dependency facts come from `atlas deps` and `atlas impact`.

## Corpus Check
- 1157 files · ~1,260,412 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 22942 nodes · 56119 edges · 935 communities (823 shown, 112 thin omitted)
- Extraction: 92% EXTRACTED · 8% INFERRED · 0% AMBIGUOUS · INFERRED: 4440 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- CameraSession
- OpcVk
- PocketCameraSession
- HevcDecoder
- OpenPocketViewCore
- String
- Duml
- UInt8
- Double
- Codable
- DatalinkDriver
- Sendable
- SwiftUI
- CameraStatus
- VideoFormat
- PlaybackFeedSession
- GimbalWaypoint
- FrameioService
- CameraSoftAP
- Color
- GimbalWaypoint
- AppSettings.swift
- OperatorPrefs
- XCTest
- View
- Text
- Double
- LucideSVGDocument
- CamCapTests
- LutCatalog
- MonitorIcon
- AssistRect
- FeedStressRuntime
- .run
- MonitorIcon
- LiveAssistState
- WatchRelayState
- Boolean
- FeedStressTests
- MultiviewSession
- ... 888 more in graphify_labels.json

## God Nodes (most connected - your core abstractions)
1. `CameraSession` - 326 edges
2. `PocketCameraSession` - 300 edges
3. `OpenPocketViewCore` - 254 edges
4. `OpcVk` - 226 edges
5. `Foundation` - 226 edges
6. `Duml` - 192 edges
7. `SwiftUI` - 159 edges
8. `Color` - 152 edges
9. `HevcDecoder` - 149 edges
10. `CameraStatus` - 142 edges

## Surprising Connections (you probably didn't know these)
- `runNegotiatedPictureRepair()` --calls--> `waitForPicture`  [INFERRED]
  ios/OpenPocketCine/CameraSession.swift → Sources/OpenPocketViewCore/MediaLiveResume.swift
- `BrandColors` --references--> `Color`  [EXTRACTED]
  Apps/Android/app/src/main/kotlin/com/opencapture/openpocketcine/Theme.kt → ios/OpenPocketCine/Assists/PeakingAssist.swift
- `StartupColors` --references--> `Color`  [EXTRACTED]
  Apps/Android/app/src/main/kotlin/com/opencapture/openpocketcine/pairing/StartupDesign.kt → ios/OpenPocketCine/Assists/PeakingAssist.swift
- `LiveCameraControlBar` --calls--> `MonitorReadoutOwnership`  [INFERRED]
  ios/OpenPocketCine/LiveCameraControlBar.swift → Sources/MonitorPresentation/MonitorReadoutOwnership.swift
- `ReadoutLifecycleProbe` --calls--> `MonitorReadoutOwnership`  [INFERRED]
  ios/OpenPocketCineTests/CaptureReadoutLifecycleTests.swift → Sources/MonitorPresentation/MonitorReadoutOwnership.swift

## Import Cycles
- None detected.

## Knowledge Gaps
- **2894 isolated node(s):** `command`, `swapchain`, `imageIndex`, `renderFinished`, `submit` (+2889 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **112 thin communities (<3 nodes) omitted from report** - run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Unit` connect `CameraMedia` to `DesqueezeAssistTests`, `PocketCameraSession`, `GlassChrome.kt`, `Duml`, `TrackingBox.kt`, `UInt8`, `String`, `Color`, `GimbalProgram`, `ControlHud.kt`, `View`, `compute`, `Double`, `StationNetworkSetup.kt`, `.run`, `PendingHeadphoneMotionManager`, `UI 2.0 reference inventory`, `MonitorZoomGeometry`, `LiveChrome.kt`, `Bool`, `EncoderPresentPath`, `Contributing to OpenPocketCine`, `Boolean`, `VideoFormat`, `MonitorMediaSelectionController`, `PlaybackLookShaderProgram`, `AssistCard`, `GimbalMode`, `CIImage`, `Action6SupportTest`, `Box`, `MediaLibraryController`, `HevcDecoder`, `CaptureShutterPolicy`, `Double`, `MultiviewStageStore`, `MediaSessionLink`, `ZebraAssistTests`, `NativeCurveDispatch`, `.createDecoder`, `LiveViewScreen`, `SharedWiFi`, `MonitorUIFlowTests`, `pairingPresentation`, `CanvasRecorder`?**
  _High betweenness centrality (0.215) - this node is a cross-community bridge._
- **Why does `Color` connect `SwiftUI` to `PocketCameraSession`, `GlassChrome.kt`, `MediaModels.kt`, `ble.md`, `UInt8`, `Duml`, `Codable`, `FacePriorityExposure`, `run_py`, `MonitorBackdropSnapshot`, `ConformPreview`, `CameraSoftAP`, `Color`, `PhysicalShootingModeTests`, `DiscoveryPermissions`, `MonitorCameraCard`, `compute`, `FalseColorReference`, `MultiviewScreen.kt`, `CamCapTests`, `LutCatalog`, `Bool`, `go-public.sh`, `StationNetworkSetup.kt`, `LiveAssistTool`, `.mean`, `MonitorRecoveryOverlay`, `.render`, `MonitorSnapshotRows`, `MonitorAssistPaletteReveal`, `.tick`, `LiveChrome.kt`, `FeedPresentPolicy`, `LiveFrameSampleBus`, `AndroidSessionWire`, `GuidesAssist.swift`, `MonitorAssistPaletteReveal`, `duml_parse.py`, `VectorscopeAssist`, `opc_vulkan.cpp`, `MonitorDrumSelectionTests`, `Action6SupportTest`, `repairDatalinkEndpoint`, `MonitorZoomDisc`, `CaptureShutterPolicy`, `Double`, `ProblemReportImage`, `ZebraAssistTests`, `TrackingBoxTests`, `RecoveryReason`, `ApertureStrategy`, `ViewModifier`, `LocalVPNFilterTests`, `GimbalProgramZoom`, `LiveHeadTrackAxisDials`, `MonitorLayoutRegion`, `Point`, `LivePortraitChrome`, `CameraMedia`?**
  _High betweenness centrality (0.083) - this node is a cross-community bridge._
- **Why does `OpenPocketViewCore` connect `HevcDecoder` to `String`, `Double`, `Codable`, `.playbackScopeOverlays`, `CameraStatus`, `ci-install-swift-android.sh`, `FrameioService`, `CameraSoftAP`, `GimbalWaypoint`, `OperatorSetup.kt`, `AppSettings.swift`, `FalseColorReference`, `LUTExposureCompensation`, `LutCatalog`, `Job`, `MonitorIcon`, `FeedStressRuntime`, `Boolean`, `MultiviewSession`, `LiveAssistTool`, `.transportHeader`, `MediaPhotoViewer`, `String`, `Kind`, `FieldMonitorLayout`, `CapturePickerPanel`, `LiveFrameSampleBus`, `ColorMode`, `index.mdx`, `MonitorExposureGauge`, `AndroidSessionWire`, `FeedIncidentRuntime`, `MonitorMediaSelectionInteraction`, `MonitorZoomTapStops`, `MultiviewSession`, `LiveControlSheetContent`, `MonitorWindowGeometry`, `VectorscopeAssist`, `StartupChrome.swift`, `opc_vulkan.cpp`, `PlaybackAudio.swift`, `SettingsRowCard`, `ProblemReportImage`, `NSObject`, `Canvas`, `PhysicalStationSetupTests`, `RecoveryReason`, `Boolean`, `ViewModifier`, `CaptureReadoutLifecycleTests.swift`, `BuiltInLook`, `EncoderFormatChangeTests`, `MonitorLayoutRegion`, `ManualReportHTTPStub`, `LivePortraitChrome`, `CameraMedia`?**
  _High betweenness centrality (0.060) - this node is a cross-community bridge._
- **Are the 15 inferred relationships involving `CameraSession` (e.g. with `BleLink` and `LiveFaceDetector`) actually correct?**
  _`CameraSession` has 15 INFERRED edges - model-reasoned connections that need verification._
- **What connects `command`, `swapchain`, `imageIndex` to the rest of the system?**
  _2920 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `CameraSession` be split into smaller, more focused modules?**
  _Cohesion score 0.025745218123240356 - nodes in this community are weakly interconnected._
- **Should `OpcVk` be split into smaller, more focused modules?**
  _Cohesion score 0.012345679012345678 - nodes in this community are weakly interconnected._
