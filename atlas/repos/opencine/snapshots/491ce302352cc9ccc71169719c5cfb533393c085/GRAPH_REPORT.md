# Graph Report - opencine@491ce302352c  (2026-10-02)

## Atlas provenance
- Source: `opencine@491ce302352cc9ccc71169719c5cfb533393c085` (ref `main`, baseline)
- Exact provenance, exclusions and coverage: `snapshot.json` beside this report.
- Navigation aid only. Dependency facts come from `atlas deps` and `atlas impact`.

## Corpus Check
- 639 files · ~547,676 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 12054 nodes · 29080 edges · 510 communities (458 shown, 52 thin omitted)
- Extraction: 91% EXTRACTED · 9% INFERRED · 0% AMBIGUOUS · INFERRED: 2527 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- OpcVk
- UInt8
- Duml
- CaseIterable
- PTPLiveViewFocusInfo
- PTPPropertyCode
- MonitorIcon
- MonitorBackdropRenderer.swift
- PTPCameraPropertyDecoders
- MonitorIcon
- View
- Sendable
- ColorMode
- CompressedAccessUnitAdmission
- Testing
- UCD2Frame
- MonitorLayoutPolicy
- FakeLuna
- SettingKey
- Int
- Data
- reportedCamera
- PTPIPHandshakeTests.swift
- Run
- .readUInt32LE
- LucideSVGDocument
- ikcp.c
- Bool
- SessionRecoveryState
- Hashable
- MonitorMediaSelectionController
- Equatable
- LivePipelineCadence
- VideoFormat
- OperationID
- MonitorMediaSelectionInteraction
- LunaNotification
- LunaCameraSession
- FieldMonitorLayout
- CameraBackendEvent
- ... 458 more in graphify_labels.json

## God Nodes (most connected - your core abstractions)
1. `String` - 1076 edges
2. `Data` - 399 edges
3. `Foundation` - 265 edges
4. `OpcVk` - 226 edges
5. `Testing` - 158 edges
6. `Duml` - 119 edges
7. `PTPIPSavedCameraRecord` - 112 edges
8. `MonitorIcon` - 94 edges
9. `PTPPropertyCode` - 92 edges
10. `Commands` - 90 edges

## Surprising Connections (you probably didn't know these)
- `tokenDecodesFromIMSResponse()` --calls--> `Data`  [INFERRED]
  Tests/OpenCineFrameIOTests/FrameioOAuthTests.swift → Sources/Insta360Protocol/UCD2.swift
- `recordsWithoutThePathFieldStillDecode()` --calls--> `Data`  [INFERRED]
  Tests/OpenCineNikonTests/CameraPathTests.swift → Sources/Insta360Protocol/UCD2.swift
- `savedRecordDetectsUSBTransportByLabelAndHostKey()` --calls--> `PTPIPSavedCameraRecord`  [INFERRED]
  Tests/OpenCineNikonTests/CameraTransportPolicyTests.swift → Sources/OpenCineNikon/PTPIPSavedCameraRecords.swift
- `generatedVerifierIsValidLengthAndCharset()` --references--> `Set`  [INFERRED]
  Tests/OpenCineFrameIOTests/FrameioOAuthTests.swift → Android/core/src/main/kotlin/com/opencapture/opencine/core/Commands.kt
- `Rig` --calls--> `FakeLuna`  [INFERRED]
  Tests/HarnessTests/Simulated.swift → Sources/Insta360AppleTestSupport/FakeLuna.swift

## Import Cycles
- None detected.

## Knowledge Gaps
- **2198 isolated node(s):** `VIDEO`, `PHOTO`, `OTHER`, `IDLE`, `RECORDING` (+2193 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **52 thin communities (<3 nodes) omitted from report** - run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `String` connect `String` to `UInt8`, `Duml`, `CaseIterable`, `PTPLiveViewFocusInfo`, `MonitorIcon`, `MonitorBackdropRenderer.swift`, `PTPCameraPropertyDecoders`, `MonitorIcon`, `View`, `Sendable`, `ColorMode`, `UCD2Frame`, `MonitorLayoutPolicy`, `SettingKey`, `Int`, `Data`, `PTPIPHandshakeTests.swift`, `.readUInt32LE`, `LucideSVGDocument`, `ikcp.c`, `Bool`, `SessionRecoveryState`, `Hashable`, `MonitorMediaSelectionController`, `Equatable`, `LivePipelineCadence`, `VideoFormat`, `OperationID`, `MonitorMediaSelectionInteraction`, `LunaNotification`, `LunaCameraSession`, `FieldMonitorLayout`, `CameraBackendEvent`, `ProtoMessage`, `FakeCameraSession`, `LunaBackend`, `LunaCameraBackend`, `HevcDepacketizer`, `opc_vulkan.cpp`, `LunaControl`, `PTPIPSavedCameraRecord`, `CameraSnapshot`, `LunaCameraSession`, `MonitorAssistPaletteLayout`, `InfrastructureDiscoveryTests.swift`, `entry`, `LunaRequest`, `PTPEvent`, `PTPIPPacketType`, `SwiftUI`, `ScreenControl`, `Double`, `Double`, `FakeCameraSession`, `StillDriveMode`, `Offset`, `LunaProtocol`, `MonitorEntryID`, `MonitorCaptureTabRow`, `PTPUSBContainer`, `Timecode`, `PTPObjectTransferError`, `FakeLuna`, `MonitorCameraCard`, `.tick`, `LunaProtocol.swift`, `Rig`, `MonitorComponents.kt`, `MonitorQuickInteraction`, `CameraWiFiScreenParser`, `FrameioAPIRequest`, `Value`, `ChaosExperiment`, `reportedCamera`, `MediaFile`, `ClipColorProfile`, `AdmissionReason`, `Identity.swift`, `FrameioConfiguration`, `Int`, `CameraDiscovery`, `.optionLabels`, `entry`, `LunaWire`, `CameraControls`, `UVCVideoSource`, `MonitorMediaAction`, `.encode`, `CameraStartupPolicyTests.swift`, `djiLike`, `ResourceAdmission.kt`, `CameraBackendError`, `MonitorPage`, `.resolve`, `CameraSoftAP`, `DiscoveredCamera`, `.canonicalized`, `hex`, `IsoIndex`, `CameraPath`, `ISOPickerPolicy`, `Set`, `MonitorEntryDescriptor`, `MonitorValueDrum`, `MonitorControls.swift`, `client`, `USBHandshakeDiagnostic`, `CameraConnectionPhase`, `PTPIPSavedCameraRecords`, `FrameioClient`, `FakePort`, `PTPOperation.swift`, `.nalHeaders`, `MediaObjectHandle`, `Identity.kt`, `MonitorTheme`, `.decide`, `LiveFalseColorScale`, `.polledProperties`, `MediaLibrarySort`, `LUTExposureCompensation`, `.group`, `CameraLinkPhase`, `MonitorZoomDial`, `.bootstrapOverBluetooth`, `LunaIMUSample`, `.diagnose`, `MonitorFeedbackPolicyTest`, `RouteOffer`, `MonitorReadoutSnapshot`, `LogColorTransform`, `CubeLUTTests.swift`, `DecoderErrorLifetime`, `MonitorAssistPaletteReveal`, `MonitorSnapshotRows`, `LocalizedError`, `ControlWireEvent`, `LunaProto`, `MonitorDurationDial`, `MonitorChromeButton`, `ProactiveWiFiJoinSessionPolicy`, `WhiteBalanceKelvinPolicy`, `VideoToolboxDecoderTests`, `Stage`, `ShutterAngle`, `MotionBounds`, `LunaControlTest`, `MonitorAssistIcon`, `GimbalProgram`, `Box`, `FrameioModelsTests.swift`, `.label`, `MonitorInspector`, `MonitorAssistPaletteReveal`, `FakePictureSource`, `LUTSource`, `LiveVideoCodec`, `.candidate`, `WatcherRelayControlLease`, `WatcherRelayFrameMetadata`, `LunaStatusTest`, `.ranked`, `LunaTCPTransport`, `MediaHTTP`, `LUTSelection`, `CubeLUTTests`, `FrameRateSampler`, `LinkThroughputSampler`, `record`, `LocalIPv4Interface`, `LiveAccessUnit`, `VideoToolboxDecoder.swift`, `CodingKeys`, `MonitorDrumDrag`, `.disconnect`, `MonitorMediaDragSelection`, `BuiltInLook`, `.pathChipLabel`, `MediaContentKind`, `MonitorPlaybackFooter`, `WatcherRelayTests`, `MonitorZoomScale`, `MonitorDurationDial`, `.run`, `MonitorInspector`, `.lunaClockSet`, `Icon`, `MonitorToolUsage`, `.check`, `MonitorDrumSelection`, `.names`, `StationJoin`, `.normalizedHost`, `MonitorZoomScale`, `CameraPageIcon`, `FirstPictureStep`, `NativeProgramZoomCommand`, `FrameioError`, `MonitorMediaFilterForm`, `Request`, `.command`, `StoredFrameioToken`, `NikonControlSetting`, `HevcTests.swift`, `MonitorAssistPalette`, `InterfaceAddress`, `.swiftFiles`, `CameraMediaStore`, `EncoderPresentPathTest`, `LiveVideoNalVectorTest`, `.shouldTick`, `OfficialDJILUT`, `Failure`, `MediaFormatChip`, `MFDriveEligibility`, `MonitorDialHapticTests`, `MonitorDrawerTabs`, `.isAssociatedIPv4`, `CameraSoftAPSwitch`, `.hosts`, `LiveVideoNalVectorTests`, `MonitorZoomCaption`, `PTPDeviceInfoTests.swift`, `.controlOnly`, `MonitorImagePreview`, `LunaMediaFile`, `CameraWarningStatus`, `.autoEvCaption`, `MonitorExposureReadout`, `CustomLUTSlot`, `HevcFixture`?**
  _High betweenness centrality (0.477) - this node is a cross-community bridge._
- **Why does `os` connect `support.py` to `files`, `resolver.py`, `atlas.py`, `VideoToolboxDecoder.swift`, `Foundation`, `compat.py`, `rehearse_publish.py`, `Run`, `graph.py`?**
  _High betweenness centrality (0.074) - this node is a cross-community bridge._
- **Why does `Foundation` connect `Foundation` to `UInt8`, `Duml`, `CaseIterable`, `PTPLiveViewFocusInfo`, `MonitorBackdropRenderer.swift`, `Sendable`, `ColorMode`, `Testing`, `UCD2Frame`, `FakeLuna`, `Data`, `PTPIPHandshakeTests.swift`, `.readUInt32LE`, `LucideSVGDocument`, `Bool`, `SessionRecoveryState`, `Hashable`, `Equatable`, `OperationID`, `LunaNotification`, `FieldMonitorLayout`, `CameraBackendEvent`, `ProtoMessage`, `FakeCameraSession`, `LunaCameraBackend`, `HevcDepacketizer`, `String`, `PTPIPSavedCameraRecord`, `CameraSnapshot`, `MonitorAssistPaletteLayout`, `ScopeExposureCeiling`, `InfrastructureDiscoveryTests.swift`, `PTPEvent`, `PTPIPPacketType`, `LunaShootingMode`, `ScreenControl`, `Double`, `StillDriveMode`, `MonitorEntryID`, `MonitorCaptureTabRow`, `DumlTransportTests`, `PTPUSBContainer`, `Timecode`, `PTPObjectTransferError`, `LunaProtocol.swift`, `FeedPresentPolicy`, `CameraWiFiScreenParser`, `FrameioAPIRequest`, `Value`, `ChaosExperiment`, `MediaFile`, `ClipColorProfile`, `LiveViewWatchdog`, `AdmissionReason`, `Identity.swift`, `StreamID`, `FrameioConfiguration`, `Double`, `.optionLabels`, `DJICameraSessionAdapter`, `MonitorMediaAction`, `.encode`, `DiscoveredCamera`, `.canonicalized`, `IsoIndex`, `GimbalWaypoint`, `CameraPath`, `Set`, `Duration`, `MonitorEntryDescriptor`, `client`, `Double`, `USBHandshakeDiagnostic`, `CameraConnectionPhase`, `PTPIPSavedCameraRecords`, `FrameioClient`, `AudioMeterChannel`, `PTPOperation.swift`, `MediaObjectHandle`, `.decide`, `MonitorZoomGeometry`, `.nextEV`, `LiveFalseColorScale`, `.polledProperties`, `WatcherRelayEncodePolicy`, `MonitorReadoutInteraction`, `LUTExposureCompensation`, `CameraLinkPhase`, `WatcherRelayRecovery`, `.bootstrapOverBluetooth`, `LunaIMUSample`, `EditorLeases`, `.diagnose`, `Action`, `MonitorReadoutSnapshot`, `LogColorTransform`, `LocalizedError`, `Envelope`, `ZCameraOperationPolicy`, `DatalinkHandshakeAdmission`, `Stage`, `ShutterAngle`, `MotionBounds`, `MonitorPreviewAdmission`, `CameraPathRecovery`, `.decode`, `Timeout`, `GimbalNativeTargetStream`, `FrameioModelsTests.swift`, `.label`, `MonitorAssistPaletteReveal`, `.center`, `LUTSource`, `TrackingBox.swift`, `LiveVideoCodec`, `WatcherRelayControlLease`, `WatcherRelayFrameMetadata`, `LunaTCPTransport`, `.decode`, `CubeLUTTests`, `FrameRateSampler`, `LinkThroughputSampler`, `record`, `LocalIPv4Interface`, `VideoToolboxDecoder.swift`, `MonitorDrumDrag`, `MonitorMediaDragSelection`, `MonitorReadoutOwnership`, `MulticamCommands.swift`, `BuiltInLook`, `.pathChipLabel`, `MediaContentKind`, `Hevc`, `.run`, `MonitorGlassDensity`, `MonitorToolUsage`, `DeliveryCadence`, `HeadTrackNativeSampleGate`, `LinkSignalBars`, `PTPIPReadBuffer`, `MonitorZoomTapStops`, `.names`, `.aspect`, `.eventPollStride`, `.normalizedHost`, `.card`, `MonitorZoomDrag`, `FirstPictureStep`, `NativeProgramZoomCommand`, `Request`, `.scale`, `R3DHeaderParser`, `WatcherRelayBitrate`, `MultiviewRecovery`, `.swiftFiles`, `EncoderPresentPath`, `BodyBusyHoldPolicyTests.swift`, `ILogWhitePaperTests`, `.hosts`, `Point`, `MonitorZoomCaption`, `GimbalReach`, `PTPDeviceInfoTests.swift`, `MonitorPlaybackLayout`, `.shouldRequestEnableAfterParameterChange`, `FrameioURLSessionTransport`, `CameraWarningStatus`, `LunaSchemaTables.swift`, `MonitorExposureReadout`, `CameraSession`, `Hevc+DJI.swift`, `ImportRuleTests.swift`, `MediaSourceRulesTests.swift`, `ImportRuleTests.swift`?**
  _High betweenness centrality (0.055) - this node is a cross-community bridge._
- **Are the 16 inferred relationships involving `String` (e.g. with `.init()` and `.header()`) actually correct?**
  _`String` has 16 INFERRED edges - model-reasoned connections that need verification._
- **Are the 115 inferred relationships involving `Data` (e.g. with `.getPhotographyOptions()` and `.validateAuthorizationNotification()`) actually correct?**
  _`Data` has 115 INFERRED edges - model-reasoned connections that need verification._
- **What connects `VIDEO`, `PHOTO`, `OTHER` to the rest of the system?**
  _2268 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `OpcVk` be split into smaller, more focused modules?**
  _Cohesion score 0.012345679012345678 - nodes in this community are weakly interconnected._
