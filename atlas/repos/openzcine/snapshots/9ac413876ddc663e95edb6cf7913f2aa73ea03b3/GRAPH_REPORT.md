# Graph Report - openzcine@9ac413876ddc  (2026-10-01)

## Atlas provenance
- Source: `openzcine@9ac413876ddc663e95edb6cf7913f2aa73ea03b3` (ref `main`, baseline)
- Exact provenance, exclusions and coverage: `snapshot.json` beside this report.
- Navigation aid only. Dependency facts come from `atlas deps` and `atlas impact`.

## Corpus Check
- 848 files · ~1,239,888 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 18356 nodes · 46516 edges · 652 communities (566 shown, 86 thin omitted)
- Extraction: 91% EXTRACTED · 9% INFERRED · 0% AMBIGUOUS · INFERRED: 4009 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- Sendable
- OperatorPreferences
- MonitorLayoutPolicyTests.swift
- MonitorPanels.swift
- NativeAppRoot.swift
- OperatorSettings
- AssistConfiguration
- MediaPlayerView
- NativeCameraSession
- Int
- ZoneFrame
- MonitorExperience.swift
- FakeZRServer
- View
- MonitorRelayFrameMetadata
- Unit
- CameraControl
- SwiftCore
- Text
- ProgressivePlayer
- SwiftCoreCameraSession
- StoredLutLibrary
- OperatorSettingsScreen.kt
- PTPIPClientSession
- PTPIPPacket
- chromeStyle
- Coordinator
- ExposureAssistCameraInput
- MonitorScreen
- CodingKeys
- PTPPropertyCode
- LocalizedError
- StartupDesign.swift
- .uint16LE
- PTPCameraPropertyDecoders
- CameraSessionState
- FrameioDeliveryArtifact
- FrameioMediaPreparation.kt
- FrameioService
- CameraValue
- ... 598 more in graphify_labels.json

## God Nodes (most connected - your core abstractions)
1. `Text` - 215 edges
2. `Foundation` - 187 edges
3. `FakeZRServer` - 179 edges
4. `PTPIPClientSession` - 175 edges
5. `OperatorSettings` - 173 edges
6. `Box` - 154 edges
7. `MonitorScreen()` - 146 edges
8. `PTPIPSavedCameraRecord` - 146 edges
9. `chromeStyle()` - 143 edges
10. `OpenZCineCore` - 127 edges

## Surprising Connections (you probably didn't know these)
- `discoveryDedupeSortsAndFiltersBonjourResults()` --calls--> `DiscoveredCamera`  [INFERRED]
  Tests/OpenZCineCoreTests/CameraDiscoveryTests.swift → Sources/OpenZCineCore/CameraDiscovery.swift
- `BrandColors` --calls--> `Color`  [INFERRED]
  ios/Runner/Branding.swift → Sources/OpenZCineCore/FocusAssist.swift
- `createProjectRequestEncodesDataEnvelope()` --calls--> `FrameioCreateProjectRequest`  [INFERRED]
  Tests/OpenZCineCoreTests/FrameioModelsTests.swift → Sources/OpenZCineCore/Frameio/FrameioModels.swift
- `createFileRequestEncodesSnakeCaseEnvelope()` --calls--> `FrameioCreateFileRequest`  [INFERRED]
  Tests/OpenZCineCoreTests/FrameioModelsTests.swift → Sources/OpenZCineCore/Frameio/FrameioModels.swift
- `aCaptureStripOutsideTheFeedCannotProduceANegativeRail()` --calls--> `MonitorLayoutRegion`  [INFERRED]
  Tests/OpenZCineCoreTests/MonitorPortraitLayoutTests.swift → Sources/OpenZCineCore/MonitorLayoutPolicy.swift

## Import Cycles
- None detected.

## Knowledge Gaps
- **2995 isolated node(s):** `file-protection.sh script`, `post-swift-edit.sh script`, `session-start.sh script`, `npx`, `INCREMENTAL_BUILDS_ENABLED` (+2990 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **86 thin communities (<3 nodes) omitted from report** - run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Unit` connect `Unit` to `AndroidMediaRemoteShutter`, `Sendable`, `CameraSession`, `OperatorSettings`, `MFDriveController`, `LoopbackRelayHost`, `FakeSession`, `StepCard`, `Text`, `ProgressivePlayer`, `StartupHeader`, `OperatorSettingsScreen.kt`, `ConnectionProgressPopup.kt`, `MonitorScreen`, `LiveFeedView`, `CameraSessionState`, `AssistTool`, `RedLutDownloadScreen.kt`, `.decodeToJpeg`, `Int`, `FakeBridge`, `pumpReducedScopes`, `PlaybackAssistOptions.kt`, `String`, `FeedEffectsRenderPlan`, `MonitorRelayHost`, `Color`, `PhotographyChrome.kt`, `PairingExperience.kt`, `.run`, `SavedCamerasExperience`?**
  _High betweenness centrality (0.329) - this node is a cross-community bridge._
- **Why does `Foundation` connect `Foundation` to `Sendable`, `OperatorPreferences`, `NativeCameraSession`, `Int`, `MonitorRelayFrameMetadata`, `PTPIPPacket`, `LocalizedError`, `.uint16LE`, `.shouldHold`, `FrameioService`, `CameraValue`, `CameraWarningStatus`, `CredentialHandoffCoordinator`, `MonitorLUT`, `StillCaptureTests.swift`, `USBCameraTransport`, `ExposureSignalMapping`, `MonitorRelayHost`, `FalseColorScale`, `MediaClip`, `Coordinator`, `String`, `.sample`, `PTPIPSavedCameraRecord`, `CameraPropertyTests.swift`, `FacadeMediaBrowseCursor`, `CameraWiFiScreenParser`, `StillDriveMode`, `CubeLUT`, `MediaFilterDerivationTests.swift`, `LiveImageEffects`, `InfrastructureDiscoveryTests.swift`, `Peaking`, `MonitorRelayVideoEncoder`, `SessionRecoveryState`, `PTPStorageInfo`, `ScopeSamples`, `PTPEvent`, `LiveViewFrameTests.swift`, `ScopeFrameWireTests`, `AndroidUSBPTPTransport`, `MediaClipR3DTests.swift`, `ZCameraOperationPolicy`, `AppDiagnostics.swift`, `NativeCameraSessionError`, `PTPUSBContainer`, `MediaLibrary.swift`, `AudioMeterLevels`, `CameraStartupPolicyTests.swift`, `.discover`, `PTPObjectTransferError`, `AndroidRawControlCatalog`, `ISOPickerPolicy`, `ImageEffectsCompositor`, `LUTFileStore`, `PickerOptionPolicyTests.swift`, `WiFiJoinCoordinator`, `DiscoveredCamera`, `UIImage`, `LiveViewWatchdog`, `SwiftCoreJNI.swift`, `FrameioAPIRequest`, `PTPDeviceInfo`, `ConformPreview`, `.decide`, `JNIUSBPTPTransportHandle`, `MediaObjectHandle`, `.polledProperties`, `FakeZRMediaObject`, `FrameioConfiguration`, `CameraConnectionPhase`, `StartupCameraListRow`, `UIKit`, `StartupPermissionsCoordinator`, `.canonicalized`, `.snapshot`, `CameraLinkPhase`, `WatchSessionController`, `.search`, `MonitorDataAvailability`, `CameraPath`, `MediaFormatChip`, `String`, `.waveformLevel`, `ScriptedUSBTransport`, `.isOnLink`, `String`, `LinkThroughputSampler`, `.minutesRemaining`, `record`, `FakeZRRequest`, `PTPIPReadBuffer`, `FrameioModelsTests.swift`, `FrameRateSampler`, `ReconnectBackoff`, `.normalizedHost`, `FrameioOAuth.swift`, `LinkSignalBars`, `.eventPollStride`, `Magnification`, `.parseDimensions`, `NSObject`, `ThermalTier`, `AssistLUTTests.swift`?**
  _High betweenness centrality (0.082) - this node is a cross-community bridge._
- **Why does `Text` connect `Text` to `MonitorPanels.swift`, `OperatorSettings`, `.onCreate`, `CameraWifiCameraPreview`, `LocalFramingAssistConfiguration`, `View`, `StepCard`, `Unit`, `CameraControl`, `ProgressivePlayer`, `StartupHeader`, `FrameioInternetHopState`, `ConnectionProgressPopup.kt`, `chromeStyle`, `OperatorSettingsScreen.kt`, `MonitorScreen`, `UsbDiscoverBody`, `CameraWifiScanner.kt`, `CameraSessionState`, `AssistTool`, `RedLutDownloadScreen.kt`, `PlaybackAssistOptions.kt`, `LiveOverlayRect`, `Color`, `WearMonitorScreen.kt`, `ScopeKind`, `.portraitShell`, `MonitorCameraStatus.kt`, `WhiteBalanceTintPad`, `PhotographyChrome.kt`, `PairingExperience.kt`, `String`, `ScopeView.kt`, `PhotographyPickersTest`, `OpenZCineTheme`, `SavedCamerasExperience`?**
  _High betweenness centrality (0.070) - this node is a cross-community bridge._
- **Are the 193 inferred relationships involving `Text` (e.g. with `AssistToolCell()` and `CommandControlDialog()`) actually correct?**
  _`Text` has 193 INFERRED edges - model-reasoned connections that need verification._
- **What connects `file-protection.sh script`, `post-swift-edit.sh script`, `session-start.sh script` to the rest of the system?**
  _2995 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Sendable` be split into smaller, more focused modules?**
  _Cohesion score 0.019749672020707015 - nodes in this community are weakly interconnected._
- **Should `OperatorPreferences` be split into smaller, more focused modules?**
  _Cohesion score 0.01813092161929371 - nodes in this community are weakly interconnected._
