# Graph Report - openpocketcine@b7164c9e96ef  (2026-10-02)

## Atlas provenance
- Source: `openpocketcine@b7164c9e96ef236b5abdb1a8c93bc840275726ea` (ref `opencine/integration`, candidate)
- Exact provenance, exclusions and coverage: `snapshot.json` beside this report.
- Navigation aid only. Dependency facts come from `atlas deps` and `atlas impact`.

## Corpus Check
- 888 files · ~1,046,906 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 17687 nodes · 42880 edges · 738 communities (639 shown, 99 thin omitted)
- Extraction: 93% EXTRACTED · 7% INFERRED · 0% AMBIGUOUS · INFERRED: 2849 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- Sendable
- CaptureLists
- DatalinkDriver
- PlaybackFeedSession
- .line
- CameraSession
- HevcDecoder
- LiveAssistState
- CameraMedia
- OpenPocketViewCore
- CameraStatus
- PocketCameraSession
- recent-pr-handbook-audit.md
- OperatorPrefs
- FeedStressTests
- String
- SwiftUI
- BackdropRenderActivity
- ChromeRect
- String
- Identifiable
- AppSettings.swift
- FeedStressRuntime
- ScopeTraceRenderer
- ManualProblemReport
- BleLink
- .chrome
- ScopeExposureCeiling
- CIFeedView
- WatcherRelayTransport
- Boolean
- View
- WaveformAssist
- VideoFormat
- HeadphoneMotionBridge
- .encodeCommand
- LiveScopes.swift
- GimbalProgram.kt
- HistogramAssist
- LiveTopMenu
- ... 691 more in graphify_labels.json

## God Nodes (most connected - your core abstractions)
1. `CameraSession` - 321 edges
2. `CameraStatus` - 317 edges
3. `PocketCameraSession` - 305 edges
4. `OpenPocketViewCore` - 213 edges
5. `DatalinkDriver` - 149 edges
6. `HevcDecoder` - 148 edges
7. `MediaFile` - 144 edges
8. `SwiftUI` - 125 edges
9. `GimbalProgram` - 122 edges
10. `Foundation` - 122 edges

## Surprising Connections (you probably didn't know these)
- `BrandColors` --references--> `Color`  [EXTRACTED]
  Apps/Android/app/src/main/kotlin/com/opencapture/openpocketcine/Theme.kt → ios/OpenPocketCine/Assists/PeakingAssist.swift
- `StartupColors` --references--> `Color`  [EXTRACTED]
  Apps/Android/app/src/main/kotlin/com/opencapture/openpocketcine/pairing/StartupDesign.kt → ios/OpenPocketCine/Assists/PeakingAssist.swift
- `FeedIncidentRuntime` --calls--> `FeedIncidentRecorder`  [INFERRED]
  ios/OpenPocketCine/FeedIncidentRuntime.swift → Sources/OpenPocketViewCore/FeedIncidentRecorder.swift
- `CameraSession` --calls--> `GimbalOverlayMotion`  [INFERRED]
  ios/OpenPocketCine/CameraSession.swift → Sources/OpenPocketViewCore/GimbalOverlayMotion.swift
- `CameraSession` --calls--> `GimbalRampFilter`  [INFERRED]
  ios/OpenPocketCine/CameraSession.swift → Sources/OpenPocketViewCore/GimbalProgram.swift

## Import Cycles
- None detected.

## Knowledge Gaps
- **2049 isolated node(s):** `SETTINGS`, `MEDIA`, `PRIVACY`, `TERMS`, `LICENSES` (+2044 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **99 thin communities (<3 nodes) omitted from report** - run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Unit` connect `Unit` to `Sendable`, `CaptureLists`, `StationNetworkSetup.kt`, `LiveFaceDetector`, `PocketCameraSession`, `AssistToolGlyph`, `AssistGeometry.kt`, `MediaSessionLink`, `ChromeRect`, `String`, `Identifiable`, `OpcIcon`, `LiveViewScreen`, `LiveZoomChip`, `MediaCatalogClip`, `ReliabilityReportingConsent`, `MonitorCameraValues`, `CameraApJoiner`, `FakePort`, `pairingPresentation`, `Options`, `Color`, `LUTPickerBody`, `MultiviewSession`, `GpuOverlayBus`, `.launch`, `MonitorPageScaffold`, `CallbackOperationOwner`, `CaseIterable`, `MultiviewMulticam`, `detectPanelDrag`, `SavedCamera`, `MediaLibraryController`, `Int`, `OperatorSetup.kt`, `ScopePanels.kt`, `ReliabilityReporting`, `RoundedCornerShape`, `DatalinkDriver.kt`, `.capturePayload`, `DiagnosticCenter`, `HevcDecoder`, `MultiviewNetwork.kt`, `DjiCameraSessionAdapter.kt`, `BleLink`?**
  _High betweenness centrality (0.145) - this node is a cross-community bridge._
- **Why does `OpenPocketViewCore` connect `OpenPocketViewCore` to `DatalinkDriver`, `PlaybackFeedSession`, `MultiviewRecordContext`, `Camera`, `CameraMedia`, `CaptureQuickSnapshot`, `SwiftUI`, `LiveHeadTrackAxisDials`, `Identifiable`, `AppSettings.swift`, `FeedStressRuntime`, `CaptureControlSheets.swift`, `ScopeTraceRenderer`, `GamepadLimitHaptics`, `.chrome`, `LUTPicker`, `CIFeedView`, `MonitorRecoveryOverlay`, `View`, `HeadphoneMotionBridge`, `LiveScopes.swift`, `HistogramAssist`, `LiveTopMenu`, `FeedIncidentTests.swift`, `PlaybackAudio.swift`, `SwiftCoreJNI.swift`, `LiveGimbalControls.swift`, `TrafficLightsAssist`, `Options`, `StationNetworkSetupView`, `Color`, `MultiviewTileChrome`, `.makeSession`, `.applyIncomingStatus`, `AndroidSessionWire`, `EndpointPinnedCamera`, `MonitorUI`, `UIViewRepresentable`, `PocketFalseColorMap`, `StartupChrome.swift`, `EVMeterAssistTests`, `CameraWifiKeychain`, `LiveZoomPinchModifier`, `FalseColorReferenceOverlay`, `MultiviewWiFiControl`, `AudioMeterOverlay`, `DiagnosticCenter.swift`, `AppModel`, `.transfer`, `AddSetupView`, `TrafficLightsAssistTests.swift`, `FalseColorReference`, `ReliabilityReportingReceipt`, `UIKit`, `MultiviewSession`, `LiveGimbalSheetHost`, `.render`, `NDAssist`, `AudioAssistStore`?**
  _High betweenness centrality (0.107) - this node is a cross-community bridge._
- **Why does `PocketCameraSession` connect `PocketCameraSession` to `CaptureLists`, `DatalinkDriver`, `CameraMedia`, `PocketCameraSession.kt`, `GimbalRamp`, `CameraStatus`, `CameraNetworkPath`, `TrackingBox`, `FeedSuperResolutionScaler`, `Boolean`, `VideoFormat`, `LiveZoomChip`, `GimbalProgram.kt`, `Unit`, `GimbalProgram`, `FakePort`, `GimbalMode`, `RecoveryReason`, `SessionRecovery.kt`, `String`, `repairDatalinkEndpoint`, `.sendKind`, `.refreshTrackingHud`, `Int`, `LiveGimbalOverlay`, `.endMediaBrowse`, `DiagnosticCenter`, `GimbalStickMapping`, `FeedIncidentRecorderTest`?**
  _High betweenness centrality (0.102) - this node is a cross-community bridge._
- **Are the 8 inferred relationships involving `CameraSession` (e.g. with `BleLink` and `LiveFaceDetector`) actually correct?**
  _`CameraSession` has 8 INFERRED edges - model-reasoned connections that need verification._
- **Are the 109 inferred relationships involving `CameraStatus` (e.g. with `.actualCompactCameraPanelsMeasure128InBothOrientations()` and `NavigationFixture()`) actually correct?**
  _`CameraStatus` has 109 INFERRED edges - model-reasoned connections that need verification._
- **What connects `SETTINGS`, `MEDIA`, `PRIVACY` to the rest of the system?**
  _2077 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Sendable` be split into smaller, more focused modules?**
  _Cohesion score 0.03355704697986577 - nodes in this community are weakly interconnected._
