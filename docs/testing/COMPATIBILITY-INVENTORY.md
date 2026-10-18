# Compatibility inventory (thin-app migration)

Retained facades, aliases, stored/wire contracts, SDK adapters and copied bodies in the current
thin-app candidate. Companion of [RETIRED-OWNERS.md](RETIRED-OWNERS.md) and
[TESTER-GUIDE.md](TESTER-GUIDE.md). Updated 2026-10-10.

Status at the 2026-10-10 checkpoint: locally committed candidate. All three apps and
generated apps use the same capability-driven live and settings composition on each platform.
Pocket remains the common UI reference. Safe areas, camera pages, popups, capture headers,
circular focus reset and View Assist labels have shared owners; integration slots carry actual
hardware controls. Expanded View Assist uses short single-line captions and the
square cells used by compact favorites. Settings, inspectors and accessibility
retain full tool names.
Common false color offers CineStop, Video, IRE and Limits with LOG/709 reads. Shared scope,
peaking and two-axis mirror behavior retain native ownership and deployed preference keys.

The earlier exact twenty-gate matrix `275f8e15` retains its recorded source scope. The final
label delta passed eleven scoped gates (`e5f18775`): 3,156 Swift Testing cases in 375 suites and
177 XCTest cases, strict concurrency, 2,259 Android cases with zero failures and two known Core
skips, both iOS simulator architectures, three signed iOS builds for testing and all three full
Android consumers. Current app Android XML totals are Pocket 234, Insta 207 and Nikon 902,
with zero failures, errors or skips. Consumer staging, lint, debug/release and instrumentation
compilation passed; Nikon also passed its Wear/native packaging checks. Nine strict signatures,
six iPad profiles and four Pocket/Insta APK/JNI bindings passed. Compilation is not device proof.
The separate opt-in cleanup driver `9a909df` passed its Nikon signed build and source review;
its hardware restoration has not passed. It changes no shipping source or native admission rule.

Recorded Pocket/Luna original full camera workflows passed (`1946de9e` / `801a7c65`) at their
bound products. Luna's exact new clip belongs to SD bank 3 and is absent from internal bank 2
(`2787fbe1`); transfer and capture destination are not inferred. Pocket's receive/decoder fault
scenarios passed within their injected scope; the initiating Sentry dropout cause remains unknown.
Eleven optional generation-owned ingress diagnostics are implemented for future diagnosis.

Nikon's whole camera workflow remains failed/incomplete. Current native connection, complete
projected catalogue, ISO change/restoration and narrow layout observations retain their scope.
Initial label products passed native iPad portrait/landscape expand/collapse checks. The current
options run reached all eight false-color/read combinations, four mirror combinations and both
landscapes but failed final restoration, so the testcase is RED. Captured local mirror settings
still require restoration; later attempts stopped before preference changes because the camera
was not found. iPad automation worked without pending approval at the last readiness observation.
Background recovery, confirmed recording, exact new-clip playback/reopen and saved relaunch still
need a closed current Nikon proof. Android hardware, Dynamic Island phone edges, real two/four
camera operation, device performance and unexecuted special states remain untested.

Source ownership and official current duplication are bound by `b9c99891`, its legacy-glass
follow-up `b218c210`, and committed measurement `1819853f`. SDK/app matches include preserved
test oracles and bounded native/compatibility adapters; decreased totals do not mean zero copies.
The coding ledger counts adopted owners with scoped automated checks; physical qualification,
canonical integration and publication are separate. Pins, remotes and publication are unchanged.
Pocket/Insta exploratory UI-test edits remain preserved and excluded from commits. Existing
reference/accessibility/decoder skips and Nikon formatting/privacy-fixture failures retain their
recorded exclusions. Historical tables and every original checklist below retain their scope and
acceptance criteria.

Current product source is SDK `9a909df`, Pocket `3c753de6`, Insta `d1b8b8a5` and Nikon
`4460a435`. Shared shipping labels are committed in SDK `88899de`. These three tester documents
are a later docs-only delta. The retained-surface tables
below describe bounded native/integration/storage compatibility, not alternate common UI owners.

## Retention rules

| Reason | Required evidence |
|---|---|
| App composition | Actual caller wires integration/source facts, brand content, storage/account namespace or a bounded native view/operation; it does not own a second common page or scheduler |
| Deployed contract | Existing JNI/JVM/library name, saved raw value/key, keychain service, filename/address or network schema must survive upgrades and existing consumers |
| SDK/OS adapter | Actual native transport, decoder, sensor, Photos/share/OAuth/permission/filesystem or third-party SDK boundary stays in its declared layer |
| Compatibility API/test donor | Original public entry or fixture still exercises its shape; add/migrate/remove and preserved assertions govern retirement, not an assumed shipping caller |
| Hardware facts | Observed Nikon/DJI/Luna capability, calibration or source behavior stays integration-owned; unknown remains nil |
| Active copied owner | Actual copied common behavior remains; state its caller and finite ownership gap rather than calling it main parity indefinitely |

## OpenCine retained surfaces

| Surface | Current reason and caller |
|---|---|
| `OpcVulkan`, `DjiNative`, `NikonNative` classes and exported symbols | Deployed JNI contract. The legacy renderer package stays `com.opencapture.openpocketcine.feed`; source declarations on both sides are preserved. Pocket Android v6 and Insta v8 actual APK/JNI linkage audits passed for their recorded packages and retained names; current Nikon v5 APK/AAB/staging/DEX/JNI audit passed (`5a13191a`), with 99 debug/81 release production native DEX methods, 18 unused Vulkan methods removed by unchanged R8 rules and all 99 production native exports retained. Source declarations alone do not qualify another artifact |
| Android DJI `PocketCameraSession`, `PocketSessionHost`, `PocketPhase`, `PocketControlState`, `PocketControlPort`; aliases `DjiCameraSession`/`DjiSessionHost` | Integration API/JVM compatibility. Pocket `AppModel`/`AppSessionHost` and original preview fixtures exercise these names. Rename only through add/migrate/remove; these are not neutral brand-policy branches |
| DJI session/control/route identities and `CameraModel` DJI profile/name initializer | Integration-owned identity/catalogue compatibility. Actual DJI controls and original Pocket model fixtures resolve the DJI profile here; neutral vocabulary does not infer a brand from a name |
| `MonitorUI` presentation aliases and `MonitorPresentation.MonitorPreviewAdmission` | Public import compatibility. Scope placement aliases delegate Presentation; preview admission delegates Media. Actual P/I preview imports and existing tests retain these paths, not copied timing policy |
| Kotlin Library original constructor with positional/trailing sleep compatibility | Original API delegates the same Library owner with immediate scanning. Existing tests/clients retain it; current app adapters may select the explicit scanning constructor. Positional syntax alone is not evidence that the legacy overload is still the shipping path |
| Kotlin Media return scheduler | Recorded boundary exception `e67c7460` admits only six existing Core-exported coroutine primitives in `MonitorMediaReturnSession`; Swift uses language concurrency. No new dependency, upward edge, Main/global dispatcher or broad import exemption |
| `LegacySavedCameraCodec`, `BodyRecordsV0`, `SavedCamerasStore.Legacy`, `legacyKeepScreenAwake`, `LEGACY_COMBINED` favorite authority | Real saved-data migrations. P/I saved-camera stores and Pocket/Nikon media codecs still read these; removing them would discard prior installs' state |
| Atlas Insta `source-copy` edges, products and dated docs | Registry facts still describe their registered main/integration refs, not this locally committed candidate. Product-source retirement does not authorize a registry/ref/pin move; no build depends on atlas |

## OpenPocketCine retained surfaces

| Surface | Current reason and actual boundary |
|---|---|
| `OpenPocketViewCore` and `OpenPocketCineAndroid` product/library names | Public module/deployed library compatibility. View core is now 76 production lines in six files: shared DJI/Media/Motion/Relay re-exports, `ConnectionPhase`, and the telemetry/wrist-copy snapshot adapter; no saved-camera/control/math copy |
| Four Android facade sources and six `SwiftCore` exports | Real JNI address/array adapter. `FeedEffectsWire` uses the Media lattice and `LUTLibraryWire` the shared packer with DJI look facts. False-color traversal/packing no longer lives here |
| Preferences/keychain/cache paths and raw migrations | Keep `openpocketcine.*`, `com.opencapture.openpocketcine.*`, `OpenPocketCine.frameio`, shot-color/LUT/upscaler/saved-camera keys and namespaces. Actual preference, credential and media adapters still use them |
| iOS `CameraSession`, `DJIAppleTransport` and actual composition extensions | Bounded DJI/native/source admission, owner identity, telemetry, controls and exact route/URL/storage facts remain. Common media scheduling/return and command first-dispatch policy use shared owners; no `MediaSessionLink` reflection remains |
| `LiveAssistEngine`, look/preview/native picture constructors and `FeedWorkingRaster` | Integration/native constructor facts and inherited fixture/API compatibility. Actual immutable backdrop raster/cache/lifecycle is shared; the legacy mutable raster helper is retained explicitly, not counted as a newly retired body |
| `CameraMedia.cacheEntries` and one-record original/thumbnail/download/delete facades | Filesystem/source adapter over existing Library/cache/IO authority. Actual public media pages call `originalImageBytes`/`thumbnailBytes`; `cacheEntries` itself has no shipping call found in this audit and remains a legacy/test facade rather than a second cache owner |
| `AudioLevelTapBox`, native audio sinks, picture leaves, `MonitorBackdropFeed`, `GpuOverlayBus` | Actual SDK/Compose bridge. The peak accumulator, audio cadence, effects/scopes, raster queue and GL backend are shared; app leaves connect Media3/native frames/passive image sources and current layout callbacks |
| `rememberPlaybackMonitorGlass`, level/geometry/preview forwarding entries | Small compatibility/OS leaves. Playback pixel transforms and pan are shared; the old glass constructor has no shipping caller found. Pocket's one-line `InspectorPreviewRenderer()` uses NativeGlBackend and remains exercised by an original instrumented host |
| `BrandColors`, `OpcFonts`, `LiveType`, `LiveDesign`, icon/palette/usage values and log subsystem | App content/configuration and persisted choices. Settings and live rendering consume shared owners; `SettingsPalette` still supplies actual color values to the common inspector |
| Watch app and `WatchRelayState.snapshot`/wrist copy | Actual app wrist telemetry/source facts and app-name content over shared transport/UI; no app-owned wrist network/clock recipe |

`AppRoot.liveOperatorPanel` has no remaining reference. `LiveChromeThrottle`, `GamepadOperator`,
`SessionRecoveryCopy`, `PlaybackVideoLayout`, `GimbalStickLuma`, `ExposureMeterReading` and
`CameraWiFiQRCode` are now shared owners; saved-camera connection/Wi-Fi/identity types belong DJI.
They are no longer reasons to retain app copies.

## OpenInstaCine retained surfaces

| Surface | Current reason and actual boundary |
|---|---|
| `OpenInstaViewCore`, `OpenInstaCineAndroid`, `com.opencapture.openinstacine.monitor` and version-code names | Renamed products are adopted. View core is 197 production lines in seven files: shared exports/`ConnectionPhase`, actual Luna I-Log profile, legacy reach/initializer compatibility and wrist telemetry projection; no DJI wire parser copy |
| Six current `SwiftCore` exports and four facade sources | JNI adapter over shared Media with actual Luna color/profile values. Prior eight-export evidence is historical, not a current symbol count; `cameraSoftAPDecision`/`conformPreviewJSON` remain absent on Insta |
| Saved Pocket-derived namespaces and baseline attribution | Deployed contract/license history, including the shared renderer's legacy package, camera-Wi-Fi preferences/key alias and original approval/keychain defaults. Renaming module/package did not rename saved data |
| `ClipColorProfile`, `LogColorTransform`, converted-clip gamma metadata | Actual Luna playback/export still reads or writes `com.dji.camera.ColorGammaSxS` for legacy converted files. This stored content is not permission to inject DJI live calibration or infer a DJI camera profile |
| `LunaMonitorColorProfile`, bundled I-Log look and bounded live/preview adapters | Actual I-Log curve and unreported calibration remain Luna facts. The old shared 223/247 DJI calibration injection is retired; original DJI positive goldens are explicit integration fixtures. Unknown Luna calibration stays nil |
| `HeadTrack` reach/default constructors and `WatchRelayState.snapshot` | Inherited app-visible reach/field-of-view and wrist telemetry compatibility, delegated to shared Motion/Relay. Bounds remain actual adapter values; the native programmed lifecycle is shared |
| `CameraSession`/controls/core, `CameraMedia`, Kotlin `session/PocketCameraSession` | Actual Luna source/status/commands/URL/storage adapters; commands remain through LunaCameraSession. Programmed motion uses shared MotionProgramSession. Kotlin reconnect execution still drives Luna native connection using the shared recovery policy; it is not credited as a fully retired recovery runner |
| Aperture compatibility host cases | Exhaustive shared setting/legacy API cases remain, while the actual Luna profile exposes no aperture service. Unavailable entry reports refusal; no aperture page or invented observation is supplied |
| Native picture/audio/sensor/permission bridges, brand/theme/palette/log and provider credentials | Same bounded OS/configuration roles as Pocket, with actual Luna facts. Native look/native source acquisition is not a second common inspector/page/runtime |

Pocket source-sync scripts, stamps and build inputs remain retired. `baseline-provenance.json`,
NOTICE, THIRD-PARTY-NOTICES and legal attribution remain history/license data. Multiview stubs
remain removed; live Luna gimbal-limit feedback remains supported. Existing aliases used by
instrumented tests and `FalseColorReferencePositions` used by `MonitorUIReview` are compatibility
fixtures, not evidence that the old assist UI owner is still required.

## OpenZCine retained surfaces

| Surface | Current reason and actual boundary |
|---|---|
| Nikon protocol/property/discovery and infrastructure/USB adapters | Actual passive discovery, admission, PTP objects/raw angles/property descriptors, RAW/rating/card/codec/lens/AF/e-VR/HDMI/UVC facts. Hardware admission changes still need hardware-qualified reasons |
| Calibration/look tables, `ExposureScale`, `FalseColor`, `FocusAssist`, `TrafficLightsMeter`, RED facts and thermal policy | Nikon-only facts and stored meaning. Generic lattice/transfer math delegates Media; native calibration/sampling bodies are preserved |
| `OpenZCineCore.MonitorAssistTool`, stored DISP/field/panel vocabulary | Codable/stored compatibility, including retired MAG decoding and actual Nikon tool extensions. Actual UI projects into common tool/descriptor inputs; stored cases are not a copied common screen |
| `NikonMonitorShell`, `MonitorUnified`, `MonitorScreen`, `OperatorSettingsScreen`, root cover fragments | Actual descriptor/borrowed-display and typed hardware adapters into the same live/settings body used by Pocket, Insta and generated apps. Focus reset, headers, safe area and popup chrome have shared owners. Native panels supply controls only; normal SwiftUI lifecycle publishes active scene state. No dummy session/display or unsupported option is supplied |
| `MonitorOverlays` legacy playback overlay/`MovablePanel`, `PaletteStrip`/scope compatibility entries | No current live/player adopter call to the old playback overlay was found. Original/developer/public helper shapes remain; actual full players/live use common scope/panel owners. Do not justify these as a required copied shipping screen |
| Kotlin `MonitorFrameRateSampler` in `MonitorReadouts.kt`, called by `MonitorScreen.kt` | Captured follow-up `8a8e41dd` delegates the rolling algorithm to existing Media FrameRateSampler. The 15-line adapter retains ns-to-seconds and observable READY/rate label facts; 30 intervals/1 Hz and original tests stay exact. Recorded full Android v5 consumer passed; current physical readout/camera behavior untested |
| `MediaCacheStore`, `MediaCacheObjectIdentity`, `MediaCacheSettingsState` | PTP identity and synchronous filesystem/receipt adapters over shared ProgressiveMediaCache and canonical Library directory. MainActivity constructs one actual cache adapter. Settings count/clear Tasks belong the shared cache model; there is no second app Settings scheduler |
| `RelayBitrateAdaptation`, relay/watch protocols and facade aliases | Original API wrappers delegate shared adaptation/framing/control owners. Distinct deployed `_openzcine-mon._tcp`, monitor v2 and watch v1/JPEG/HEVC payloads survive; runtime convergence did not change wire schema |
| 25 `SwiftCore` JNI declarations/exports and `AndroidLiveViewPolicyWire` | Real integration/facade contract. Source-side names match; no new binary-symbol proof asserted. `feedEffectsScalars` has no actual shipping invocation found but remains both-side ABI; ignored/dead surfaces await synchronized qualified removal |
| Native media/picture/export/Photos/share/OAuth/network-hop leaves and Frame.io secure/history adapters | Actual OS/integration IO and persisted provider keys. Existing shared playback/delivery/cache owners schedule and retire them; account card/consent/busy/error is shared. K browser launch restores the captured lease on Settings retirement; Swift auth completion restores on finish |
| Closed diagnostics journal, historical exit reader | Existing Nikon event/file/report contract. Bounded report formatting/runtime is shared. The Sentry/OkHttp adapters moved to OpenCine's optional adapter products (`OpenCineSentryApple`, `:appkit-sentry`, 2026-10-12) |
| Frozen Vulkan/Media3/Nikon donors and original parity tests | Independent pixel/wire/native oracles and app-hosted assertions. Retain them through actual qualified comparison; shared source/test success alone does not authorize deleting original assertions |

The previous reasons that common Catalog would need no-op operations, Settings would need a
whole-tab slot, and the account card lacked switching/consent/error ports no longer describe
current source. Captured access, borrowed display, optional setting/services and the existing
Account/Cache owners are exercised by actual adopters. Unsupported features stay absent.

## SDK leaves and original tests across the apps

| Retained group | Audited reason |
|---|---|
| Swift/Kotlin Sentry sink, OkHttp upload and reliability transport tests | Moved to OpenCine's optional adapter products and their tests (2026-10-12); the apps keep holder tests only. Shared reliability policy/formatting still does not import these dependencies |
| DiscoveryPermissions, app crash-guard preference adapter and associated tests | OS permission/storage/log values; guard behavior is shared native-runtime |
| App backdrop/preview factories, native Bitmap/ImageIO/Media3 audio/picture bridges | Real native acquisition/render/API bridge. App `Media3GlBackend` production copy is gone; the original donor lives only in pixel-conformance tests |
| BackdropRenderActivity, MonitorMotionInputTest and app-hosted UI instrumentation | Developer activity/device/test setup, actual app bindings and original interaction assertions; not production common-owner substitutes |
| LiveLevelOverlay and SettingsPalette tests | Actual geometry forwards to shared level math/UI; app sensor acquisition/palette content remains. Tests still pin the deployed app labels/values; the old claim that Pocket draws a separate level renderer is stale |
| AppModel watcher/audio/zebra/Wi-Fi wrappers and log facade | Shared watcher/assist/QR implementations are adopted; remaining app methods supply current model/source/service name, saved keys and log content |
| Encoder-format, staging-lease, status-chrome, LUT, camera/Wi-Fi/watch/nav/preferences and bundled-resource tests | Actual native or app-contract assertions. Keep their original expectations and payloads when changing compatibility fixture setup; preserve intentional corrections explicitly |
| Frozen SDK/input captures | Byte identities qualify only their recorded inputs and platform scope. Compilation, simulated fixtures and optional physical-driver source are not physical success |

## Follow-up disposition

| Earlier IDs | Current disposition |
|---|---|
| O-1, O-2 | Retain deployed integration names and original Library constructor through add/migrate/remove; no second owner |
| O-3 | Registry/ref/pin facts require authorized final integration; not changed here |
| P-1, I-2, I-3, I-5, I-6, I-8 | Source aliases/dead code, neutral vocabulary/platform moves, module/package rename and multiview-stub retirement are implemented; saved namespaces/provenance remain |
| P-2 | Vocabulary/DJI owns former view-core twins. App wrist snapshots are telemetry/content adapters |
| P-3 | Media lattice adopted by all three facades and real Pocket look baking; original paint/weight/Float/byte goldens preserved |
| P-4, I-4 | Common tracking/input/pan/incident/library/live/settings/photo/player/delivery/watcher/preview owners are adopted. Bounded IO, third-party sinks, sensor/source factories and original test facades remain; complete current consumer/physical qualification is separate |
| P-5 | One-line native preview factory remains original instrumented compatibility; actual renderer/pipeline is shared |
| P-6 | `liveOperatorPanel` is absent; cover state comes from AppShell |
| I-1 | Shared recovery decisions and programmed-motion lifecycle adopted; bounded Luna reconnect runner still remains and is not claimed retired |
| I-7 | Legacy converted-file metadata remains. DJI live calibration/profile branching is retired; Luna uses actual I-Log values. Aperture compatibility cases do not advertise a service |
| Z-2 | Common tool/scope/panel/account/player/live owner adoption is implemented; stored/native facts and legacy helper APIs remain. FPS rolling calculation delegates the existing shared sampler; recorded Android v5 consumer passed; committed source/deltas are bound and physical qualification remains untested |
| Z-3 | Canonical shared progressive/cache/library/catalog/photo/player owners and typed access/rating/staging adapters are implemented; actual native/hardware qualification and original donors remain |
| Z-4 | Declared ABI/dead-entry cleanup remains a both-platform qualified removal; no silent JNI change |
| Z-5 | Runtime/reader/control/framing/watch composition is shared; deployed schemas remain distinct |
| Z-6 | Passive discovery remains integration/OS hardware behavior; no unqualified discovery rewrite |
| Z-7 | Actual borrowed-display settings/cache/account/root adoption is implemented; recorded Android v5 and native v15 gates passed, with two known native skips; local source/deltas are bound and physical installation remains untested |
| Z-8 | Shared descriptor uses captured fields and editable sections. The exact REC/clock/lock eye UX criterion is not credited closed by this source audit; bind actual two-platform UI evidence |
| X-1, X-2, X-3 | Shared shader/staging/bootstrap/tester checks and protocol probe owner references are implemented. Each app keeps pre-pin bootstrap/thin wrappers; Nikon's different TestFlight contract remains |

Root closed the original Pocket/Insta compatibility exits in `2415a4b7`; this table grants no
additional checkpoint credit. Nikon common composition and current scoped consumer gates are now verified.
Physical Nikon acceptance remains incomplete and separately tracked. Earlier
first-pass candidate/matrix evidence retains its original scope. The
historical pending prose below is retained as dated provenance, not current status.

## Current normalized duplication, 2026-10-10

Official measurement `1819853f` uses SDK `9a909df` and the three current committed consumer
refs above. No missing sources or pair growth against the original baseline `3ee29c52`.
The six pair counts include test oracles and normalized block matches, not distinct source LOC.

| Pair | Current duplicated lines | Change from original baseline |
|---|---:|---:|
| OpenCine / OpenInstaCine | 706 | -18,508 |
| OpenCine / OpenPocketCine | 256 | -2,249 |
| OpenCine / OpenZCine | 434 | -238 |
| OpenInstaCine / OpenPocketCine | 9,836 | -45,459 |
| OpenInstaCine / OpenZCine | 584 | -132 |
| OpenPocketCine / OpenZCine | 523 | -1,164 |

Pocket's legacy `GlassChrome.resolveTier` has no shipping callers and remains exercised by its
original tests. Nikon's matching policy still drives the legacy Kyant/native presentation path.
Shared sampled-blur capability supports API 31/32; the legacy tier contract requires API 33.
Replacing it mechanically would change behavior. Keep that declared native compatibility leaf;
it is not evidence of a second common live composition. Native JNI, account/keychain/route,
ImageIO and wire/schema leaves and their independent test oracles remain bounded adapters.

## Historical compatibility snapshot and measurements

The previous inventory's candidate was OpenCine `aed102b9`, Pocket `3e429797`, Insta `ed7e0089`,
Nikon `25a49155`; compat heads were shared `54e2d41`, Pocket `2216acb5`, Insta `32caba6`, Nikon
`d462fcaf`. Retained as pre-2026-10-07 provenance, frozen in the October 7 review, not current
candidate identities. The recorded compat-only app removal was about 3,780 lines (P -1,507,
I -1,905, N -364). Its binary/JNI checks belong to that snapshot.

Historical normalized duplication (same old atlas block method; comments/imports/blank lines are
normalized, so these are not the all-line production counts):

| Pair | Registered pre-migration refs | Union at compat-lane start | After that compat lane |
|---|---:|---:|---:|
| OpenCine / OpenInstaCine | 28,525 | 8,497 | 7,749 |
| OpenCine / OpenPocketCine | 13,197 | 658 | 504 |
| OpenCine / OpenZCine | 2,117 | 498 | 466 |
| OpenInstaCine / OpenPocketCine | 55,295 | 27,599 | 25,291 |
| OpenInstaCine / OpenZCine | 716 | 227 | 206 |
| OpenPocketCine / OpenZCine | 1,687 | 275 | 248 |

The start used shared `bb500df8`, Pocket `3e429797`, Insta `ed7e0089`, Nikon `0b7e555e`. Those
numbers are preserved, not recalculated or presented as the current exit. Their old explanation
that no shared live/watcher/gamepad/assist/lattice owner existed is superseded by current actual
adoption. `atlas dupes --candidate` reads recorded refs; a pre-migration registry or stale
candidate cannot measure later uncommitted sources. The October 10 committed measurement above supplies the current binding;
no registry, candidate, pin or atlas baseline was changed.

Historical removal provenance: shared `9fe3a9f` removed unused MonitorZoomStops/DjiConnectionRoute
aliases; Pocket `2216acb5` removed dead scaler/JSON/JNI helpers, playback-frame taps and forwarding
aliases; Insta `32caba6` removed unreachable DJI parsers/commands, unused transport/LUT/audio/
multiview paths, forwarding aliases and source-sync leftovers; Nikon `fbbbd705`, `4f11941d`,
`5c8bda63` removed dead renderer/scaler/alias/tooling copies. The nikon-z1 rounds (`8bef53c3`,
`9010d9d2`, `5e175fa8`, `82acde96`, `d41a253f`, `1313f77f`, `5cf86817`, `ec3381b7`, `f6135ef1`,
`9b0afd04`, `b6a60447`, `47ce0974`, `e63a37d4`) retired control writeback, zone/core-gate shells,
unbounded zoom/decoder forwarders and old folder/catalog aliases. Their original source and
assertions remain historical evidence; the current deep page/lifetime retirements are listed in
[RETIRED-OWNERS.md](RETIRED-OWNERS.md).
