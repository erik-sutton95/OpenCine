# Graph Report - openzcine@ef38a2646e49  (2026-10-01)

## Atlas provenance
- Source: `openzcine@ef38a2646e49c248c089d6bf5d7bfca1c836dd62` (ref `feat/monitor-engine-port`, candidate)
- Exact provenance, exclusions and coverage: `snapshot.json` beside this report.
- Navigation aid only. Dependency facts come from `atlas deps` and `atlas impact`.

## Corpus Check
- 1052 files · ~1,366,404 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 21186 nodes · 52679 edges · 778 communities (680 shown, 98 thin omitted)
- Extraction: 91% EXTRACTED · 9% INFERRED · 0% AMBIGUOUS · INFERRED: 4594 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- NativeAppRoot.swift
- AppDiagnostics.swift
- MediaPlayerView
- Unit
- Sendable
- AssistConfiguration
- View
- PTPIPClientSession
- FakeZRServer
- Color
- NativeCameraSession
- PairingExperience.kt
- CameraControl
- SwiftUI
- SwiftCore
- Value
- ScopeView.kt
- Foundation
- String
- AndroidLutLibrary
- CameraSession
- MediaClipRecord
- MonitorExperience.swift
- PTPCameraPropertyDecoders
- chromeStyle
- MonitorReadouts.kt
- MediaCacheStore
- PTPLiveViewFocusInfo
- CodingKeys
- AndroidUSBPTPTransport
- PTPPropertyCode
- MonitorCameraControls.kt
- MonitorIcon
- MonitorIcon
- FrameioMediaPreparation.kt
- LocalizedError
- MediaBrowseScreen
- ExposureSignalMapping
- .start
- Coordinator
- ... 721 more in graphify_labels.json

## God Nodes (most connected - your core abstractions)
1. `Foundation` - 233 edges
2. `Text` - 211 edges
3. `FakeZRServer` - 179 edges
4. `OperatorSettings` - 175 edges
5. `PTPIPClientSession` - 175 edges
6. `PTPIPSavedCameraRecord` - 165 edges
7. `Testing` - 157 edges
8. `MonitorScreen()` - 141 edges
9. `Color` - 138 edges
10. `Box` - 132 edges

## Surprising Connections (you probably didn't know these)
- `discoveryDedupeSortsAndFiltersBonjourResults()` --calls--> `DiscoveredCamera`  [INFERRED]
  Tests/OpenZCineCoreTests/CameraDiscoveryTests.swift → Sources/OpenZCineCore/CameraDiscovery.swift
- `createProjectRequestEncodesDataEnvelope()` --calls--> `FrameioCreateProjectRequest`  [INFERRED]
  Tests/OpenZCineCoreTests/FrameioModelsTests.swift → Sources/OpenZCineCore/Frameio/FrameioModels.swift
- `createFileRequestEncodesSnakeCaseEnvelope()` --calls--> `FrameioCreateFileRequest`  [INFERRED]
  Tests/OpenZCineCoreTests/FrameioModelsTests.swift → Sources/OpenZCineCore/Frameio/FrameioModels.swift
- `relayFrameMetadataDecodesTheSharedVector()` --calls--> `Timecode`  [INFERRED]
  Tests/OpenZCineCoreTests/MonitorRelayWireVectorsTests.swift → Sources/OpenZCineCore/MonitorStateValues.swift
- `mediaCapacityLabelCombinesGigabytesAndPercent()` --calls--> `MediaStatus`  [INFERRED]
  Tests/OpenZCineCoreTests/MonitorTextFormatTests.swift → Sources/OpenZCineCore/MonitorStateValues.swift

## Import Cycles
- None detected.

## Knowledge Gaps
- **3185 isolated node(s):** `file-protection.sh script`, `post-swift-edit.sh script`, `session-start.sh script`, `npx`, `INCREMENTAL_BUILDS_ENABLED` (+3180 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **98 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Unit` connect `Unit` to `Sendable`, `MonitorPairCameraPage.kt`, `Color`, `PairingExperience.kt`, `ScopeView.kt`, `StartupDesign.kt`, `MFDriveController`, `String`, `CameraSession`, `chromeStyle`, `MonitorReadouts.kt`, `.key`, `MonitorCameraControls.kt`, `FakeSession`, `SavedCamerasExperience`, `Int`, `AssistTool`, `OperatorSettings`, `MonitorCameraCard`, `CleanScopeProcessor`, `ProgressivePlayer`, `.copy`, `LoopbackRelayHost`, `RedLutDownloadScreen.kt`, `PlaybackAssistOptions.kt`, `Text`, `RecoverySession`, `RoundedCornerShape`, `LiveFeedView`, `MediaStillViewer`, `ExposureAssistCameraInput`, `MonitorInspector`, `MonitorRelayHost`, `.decodeToJpeg`, `MonitorQuickInteraction`, `FakeBridge`, `MonitorScreen`, `.onCreate`?**
  _High betweenness centrality (0.322) - this node is a cross-community bridge._
- **Why does `MonitorScreen()` connect `MonitorScreen` to `MonitorCameraStatus.kt`, `QualityPickerPanelBody`, `MonitorRelayWire`, `Unit`, `Color`, `CameraControl`, `ScopeView.kt`, `PhotographyChrome.kt`, `MFDriveController`, `FocusFeedGeometry`, `AndroidLutLibrary`, `MonitorAnalysisPanelPlacementStore`, `CameraSession`, `chromeStyle`, `MonitorReadouts.kt`, `.key`, `MonitorCameraControls.kt`, `FocusSession`, `AndroidLinkHealthMonitor`, `FakeSession`, `resolveTier`, `LocalFramingAssistConfiguration`, `SavedCamerasExperience`, `FeedZoomTest`, `InstantReviewController`, `LiveViewGuideController`, `FeedEffects`, `AssistTool`, `OperatorSettings`, `MonitorPreviewPolicy.kt`, `CameraPropertySnapshot`, `FocusFeedGestures.kt`, `PlaybackAssistOptions.kt`, `ZoneFrame`, `Box`, `AndroidWearPhoneRelay`, `MonitorCameraControlsTest`, `FakeCameraSession`, `LiveFocusInfo`, `AudioMetersOverlay`, `feedTextureVisibleRect`, `Text`, `MonitorDisplayMode`, `RecoverySession`, `AndroidThermalTier`, `LiveFeedView`, `RoundedCornerShape`, `LiveFrame`, `LiveOverlayRect`, `executeWearRecordCommand`, `FakeBridge`, `ExposureAssistCameraInput`, `.onCreate`?**
  _High betweenness centrality (0.080) - this node is a cross-community bridge._
- **Why does `Foundation` connect `Foundation` to `AppDiagnostics.swift`, `MagnificationTests`, `Unit`, `Sendable`, `NativeCameraSession`, `Value`, `String`, `MonitorZoomTapStops`, `.eventPollStride`, `Magnification`, `.parseDimensions`, `.isOnLink`, `AndroidUSBPTPTransport`, `ThermalTier`, `LocalizedError`, `ExposureSignalMapping`, `CredentialHandoffCoordinator`, `Request`, `.card`, `MonitorZoomDrag`, `PTPEvent`, `.parse`, `.uint16LE`, `ScopePoint`, `StillDriveMode`, `FacadeMediaBrowseCursor`, `.scale`, `MediaClipR3DTests.swift`, `Double`, `MonitorAssistIcon`, `PTPOperationCode`, `FrameioAPIRequest`, `AssistLUTTests.swift`, `Timecode`, `NativeCameraSessionError`, `CameraSourceOfTruthTests.swift`, `FrameioService`, `PTPIPSavedCameraRecord`, `FocusAssistTests.swift`, `CameraPicker`, `MediaFilterDerivationTests.swift`, `AndroidRawControlCatalog`, `InfrastructureDiscoveryTests.swift`, `PTPStorageInfo`, `MonitorRelayVideoEncoder`, `Data`, `.isMajor`, `.shouldHold`, `SessionRecoveryState`, `OperatorPreferencesTests.swift`, `PTPIPPacket`, `MonitorZoomCaption`, `ScopeSamples`, `SwiftCoreJNI.swift`, `SubnetScanPlanTests.swift`, `LiveViewFrameTests.swift`, `ZCameraOperationPolicy`, `ISOPickerPolicy`, `AndroidCameraPropertyReadback`, `LUTSelection`, `PTPUSBContainer`, `UIKit`, `MulticamCoordinator`, `DispMode`, `os`, `CameraWarningStatus`, `MonitorLUT`, `FrameioConfiguration`, `.discover`, `PTPObjectTransferError`, `USBCameraTransport.swift`, `Peaking`, `MonitorExposureReadout`, `ImageEffectsCompositor`, `MonitorPlaybackLayout`, `FrameioError`, `.snapshot`, `CubeLUT`, `CameraWiFiScreenParser`, `MonitorToolUsage`, `AudioMeterLevels`, `NikonSavedCamerasView`, `MonitorMediaAction`, `CameraPropertyTests.swift`, `LiveViewWatchdog`, `FieldMonitorLayout`, `PickerOptionPolicyTests.swift`, `ConformPreview`, `.upserting`, `LUTFileStore`, `FakeZRMediaObject`, `JNIUSBPTPTransportHandle`, `MediaObjectHandle`, `DiscoveredCamera`, `.polledProperties`, `.decide`, `CameraConnectionPhase`, `MediaDelivery.swift`, `MonitorDataAvailability`, `MonitorSafeArea`, `CameraLinkPhase`, `.search`, `.canonicalized`, `MonitorZoomGeometry`, `AndroidSessionOwnerRegistry`, `MonitorReadoutSnapshot`, `MediaLUTExport.swift`, `CameraPath`, `.parse`, `.waveformLevel`, `StartupPermissions.swift`, `MonitorRelayDiscovery`, `ConnectionLifecycleTests`, `MonitorCapturePopupLayout`, `MonitorReadoutInteraction`, `MonitorPreviewAdmission`, `StillCaptureTests.swift`, `Issue`, `.side`, `MonitorAssistPaletteReveal`, `MonitorMediaDragSelection`, `String`, `MonitorAssistPaletteLayout`, `LinkThroughputSampler`, `PTPDeviceInfoTests.swift`, `record`, `MonitorDrumDrag`, `CameraTransportKind`, `Size`, `.minutesRemaining`, `PTPIPReadBuffer`, `MonitorReadoutOwnership`, `ReconnectBackoff`, `RedLUTDownloadAvailability`, `.pathChipLabel`, `.capabilities`, `FrameRateSampler`, `MonitorGlassDensity`, `.normalizedHost`?**
  _High betweenness centrality (0.061) - this node is a cross-community bridge._
- **What connects `file-protection.sh script`, `post-swift-edit.sh script`, `session-start.sh script` to the rest of the system?**
  _3185 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `NativeAppRoot.swift` be split into smaller, more focused modules?**
  _Cohesion score 0.02170309748264788 - nodes in this community are weakly interconnected._
- **Should `AppDiagnostics.swift` be split into smaller, more focused modules?**
  _Cohesion score 0.03082039911308204 - nodes in this community are weakly interconnected._
- **Should `MediaPlayerView` be split into smaller, more focused modules?**
  _Cohesion score 0.029292232190782915 - nodes in this community are weakly interconnected._
