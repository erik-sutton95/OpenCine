# OpenCineUI

The shared OpenCine UI 2.0 design system: presentation policy and native monitor
screens used by the OpenCapture camera apps (OpenPocketCine, OpenInstaCine, OpenZCine).

## Products

| Product | What | Platforms |
| --- | --- | --- |
| `MonitorPresentation` | Foundation layout, capability gates and display values over portable Media types. No camera I/O. | iOS, macOS, watchOS |
| `MonitorUI` | SwiftUI pages, controls, inspectors, canvas, media catalog; bundled Sora fonts and Lucide/assist icons. Values and actions are injected. | iOS (compiles empty elsewhere) |

The Compose implementation of the same design lives under `Android/` (`monitor-ui`).

Module names are the donor's (`MonitorPresentation`, `MonitorUI`) so the first adoption is a
dependency swap, not an import rename.

## Provenance

Extracted from OpenPocketCine `origin/main`
`27b15028e86d93798c802ddb56c7c474a30bb4c7` (`Sources/MonitorPresentation`,
`Sources/MonitorUI`, `Tests/MonitorPresentationTests`, `scripts/vendor-lucide-icons.py`).
The only source change is `MonitorTheme`, taken from OpenInstaCine
`35b6f33b20cbd791a4c24b6380046f180f1ee454`: it adds a settable `accentRGB` and `onAccent`.
The default `accentRGB` is `0x00A3E6`, the accent OpenPocketCine iOS shipped, so an app that
never sets it renders as before.

## Using it

Candidate (local) dependency, with OpenCine checked out next to the app repository:

```yaml
# XcodeGen project.yml in <app>/ios/
packages:
  OpenCine:
    path: ../../OpenCine
```

```swift
// Package.swift
.package(path: "../OpenCine")   // products MonitorUI, MonitorPresentation
```

Once a remote exists, switch to `url:` plus an exact version (or `from:`) and commit the
app's `Package.resolved`.

Brand theme: assign the accent once at launch, before any view is built.

```swift
MonitorTheme.accentRGB = 0xFFCF00  // e.g. OpenInstaCine yellow
MonitorTheme.prepareResources()    // optional: register fonts early
```

`CamerasPage(nearbyNote:)` sets the caption beside NEARBY (default `announcing over
Bluetooth`; OpenZCine passes `on this network`). `PairCameraPage { extra }` places app content in
the pane under the error and above the devices, like Compose's `extra` (the shared app shell fills
it from its integration slots, [appkit](../appkit/README.md)). Android's brand inputs are
`MonitorPalette.accent` and the transitional `MonitorIosParity.enabled`
(see [Android/monitor-ui/README.md](../../Android/monitor-ui/README.md)).

`CamerasPage` and Compose `MonitorCameraPage` own their platform's Your Cameras frame.
The Android page applies safe-drawing and landscape cutout clearance plus the Pocket page
spacing itself. Deployed app shells and generated Scenes use that same renderer; native
pairing content and route lifetime remain bounded host inputs.

Resources load through `Bundle.module`; consumers copy no fonts or icons and add no
`Info.plist` font entries.

App views share the 44 pt hit-target helpers (`.buttonStyle(.monitorTapTarget)`,
`minTapTarget`) and the solid page surface (`liquidGlass(in:)`, `glassCapsule`, `glassCircle`;
floating monitor chrome uses `monitorGlass`). Corner radius is `MonitorTheme.radius`, the page
backdrop `MonitorTheme.background`. SwiftUI only: Compose uses its own minimum touch target.
Text uses `MonitorTheme.font(size, weight:)` directly.

Live chrome geometry is shared as well. `MonitorPresentation` holds the layout policy
(`MonitorEdgeInsets`, `MonitorDeviceOrientation`, `MonitorHorizontalLayoutDirection`,
`MonitorLayoutRegion`, `StartupSideCutoutAvoidance`, `GimbalCluster`); `MonitorUI` holds the
CGRect live layout built from `FieldMonitorLayout` (`LiveMonitorLayout.fieldMonitor`,
`LivePopupPlacement`, `LiveChromeMetrics`, `InterfaceOrientationObserver`, `liveModuleFrame`
and the `interfaceLocked` environment value). The Compose twin is `MonitorLiveLayout.kt`.

Live app composition uses `MonitorOperatorLiveSurface` in `OpenCineCameraControls` /
`camera-controls`, fed by a typed source, the vocabulary adapter or the generated-app Scene. One
owner places the canvas, status, system rail, palette, inspector and capture popup.
The lower UI primitives continue to take values and actions; app-specific native content enters
bounded typed slots. See [monitor composition and capture](../appkit/README.md#monitor-composition-and-capture)
for adapter boundaries, capture ownership and regression guards.

Every camera's control popup (ISO, shutter, white balance, focus and the other drum controls)
is the one common drawer, `MonitorCapturePanel`, placed by the live surface. Inside it,
`CaptureSheetPanel` (status-reporting cameras) and `LadderSheet` (cameras that advertise label
ladders, such as Nikon) draw the same parts: the typed `MonitorCaptureDrum` or the label
`MonitorValueDrum`, the one `ModeBar` tab strip (tabs carry `monitor.capture.tab.<index>`),
and `MonitorCaptureToggle` / `MonitorCaptureStepper` rows. Neither draws its own glass, header
or close control. Camera differences (lock banners, Kelvin and bit-depth step buttons, a
two-axis tint pad) arrive as typed tab values: the ladder presentation types live in
`OpenCineCameraVocabulary` (`CaptureLadderSheet.swift`), and `NikonCapturePopupState`
(`OpenCineNikon`) builds them from session values, so an app adapter only reads its session
and routes writes. The shared `CapturePopupUITests`
(`OpenCineAppUITesting`) opens each popup in both orientations in every app.

Grouped movie-format controls live in `OpenCineCameraControls` /
`camera-controls`, above the lower UI primitives. [`CaptureFormatPicker` and
`CaptureFormatPickerState`][grouped-format-1] ([Compose][grouped-format-2])
consume exact `CaptureFormatChoice` values and optional `CaptureFormatGroup`
facts supplied by the host's capability inventory. Image area, such as FX/DX, is
separate from recording aspect. Area, aspect and resolution groups filter the
eligible frame-rate drum; sparse inventories never become all possible
combinations. Changing a group retains the selected rate when an editable tuple
allows it, otherwise choosing the first supplied editable tuple. Unknown
grouping facts stay absent; their exact choices remain visible in the
unclassified bucket.

A drum label shared by multiple distinct values in the current bucket is
ambiguous and submits nothing. Empty, disabled, read-only and removed choices
likewise submit nothing. Codec remains its separate existing control. The picker
owns presentation and local selection, not wire encoding, write authority or
camera readback. See [capture composition][grouped-format-3] for actual host
adapters and source admission.

[grouped-format-1]: ../../Sources/OpenCineCameraControls/Capture/CaptureFormatPicker.swift
[grouped-format-2]: ../../Android/camera-controls/src/main/kotlin/com/opencapture/opencine/cameracontrols/CaptureFormatPicker.kt
[grouped-format-3]: ../appkit/README.md#monitor-composition-and-capture

`MonitorTimecodeFormat` renders only supplied telemetry. Optional frame components
produce `HH:MM:SS:FF`; absent frames retain `HH:MM:SS`. An explicitly reported
drop-frame mode uses `HH:MM:SS;FF`. Unknown rates and modes remain unknown: the
formatter never derives frames from a timer or guesses a recording rate. The
shared clock accents the final field with either separator. Camera adapters
choose precision from their source facts, independently of recording duration.

Portrait status measures the recording, clock and format slots, keeping an 8 point/dp
clearance and using an intrinsic second row when needed. Rows contain the full native
touch targets: iOS uses 44 points; Compose reads `LocalViewConfiguration` (normally
48 dp, while the existing 52 dp tablet row stays larger). This platform sizing difference
keeps Android touch expansion inside the measured header. Typed header readouts expose
their title, optional value and presentation action as one accessible control.

The status row keeps one codec control. Portrait and landscape fold the colour readout
into it: the codec value stays visible, its tap opens the one codec and colour popup, and
a camera without a codec readout keeps its own colour control and target. Landscape speaks
both values from the combined control (`Codec and color`, `R3D NE · D-Log2`). Photography
keeps its existing stack.

The header accent follows the body's declared `MonitorHeaderAccent`: the shooting-mode
readout by default, or the codec readout for a body that has no shooting mode. The accent
stays on the declared readout only, so a header that does not show it (portrait, a narrow
landscape) stays unaccented. The profile carries the declaration; the header never tests a brand.

Phone portrait telemetry uses separate `telemetry` bounds below the safe top,
with eight points/dp of clearance and side reserves for rounded corners. The
existing `gauges` corner contract remains available to other compositions.
Storage shares a bounded row with link performance before the power readouts:
its text shrinks from 14 to 11 points/sp, then ellipsizes while accessibility
retains the full supplied value. Portrait video format/FPS and its supplied
detail form one trailing column; actionable details keep independent targets,
and a static caption retains its primary editor section. Photography, tablet
and landscape compositions retain their existing arrangement.

`MonitorFocusResetButton` owns the common circular `rotateCw` glyph and target on both
platforms. Legacy and canonical live surfaces delegate to it; apps supply visibility
and reset actions.

## Look libraries and inspector previews

`MonitorLUTPickerView<Looks, Palette, Footer>` accepts any `MonitorLookProvider` and
`LUTPickerLibrary` descriptors. Apps supply catalogue entries, optional filters, imports,
deletions and download actions. Embedded pickers leave comparison to the shared inspector
footer; standalone sheets include it once. Exposure is shown only when the provider's
`appliesLUTExposure` capability is true. The published `LUTPickerView` remains available.
Compose uses the existing `LutPickerLibrary` and `LUTPicker` equivalents.

`MonitorLookInspectorPreview<Looks>` shares image marks, scopes and audio rendering over
that same provider. Existing `MonitorOperatorInspectorPreview` source calls retain their
concrete type, defaults and contextual invalidation. A host with a calibrated native image
graph may borrow `MonitorInspectorRenderedPictureSource`: its source/presentation identity
scopes a cancellable task, and its main-actor read returns only the current immutable image
and geometry. The host retains native admission, calibration and stale-source rejection.
Audio remains an optional observation and uses the same shared meter.

`CustomLUTStore.category(named:)` retains existing root-level slots and creates isolated,
path-safe category stores. `importArchive` streams platform-decoded entries with default
limits of 16 MiB per cube, 512 MiB total and 512 cubes. It counts actual output bytes,
validates every cube before installation, rejects duplicate flattened names and unsafe
paths/symlinks, and atomically installs replacements. Platform adapters keep ZIP decoding
and checksum verification. Existing usable destinations survive malformed or rejected
input. Filesystem installation failures roll back earlier replacements; if recovery itself
fails, the typed error retains the backup directory. Android's existing `MonitorLutLibrary`
already owns category maps, bounded reads, validation and atomic storage; platform archive
decoders remain outside the shared UI.

## Operator settings

Android's deployed, configured and generated-session settings entries each build one
`MonitorOperatorSettingsConfiguration` and delegate to the sole
[`MonitorOperatorSettingsBody`](../../Android/camera-controls/src/main/kotlin/com/opencapture/opencine/cameracontrols/MonitorOperatorSettingsBody.kt).
That owner supplies the cover input barrier, safe-drawing clearance, page margins, Back action,
one row recipe per tab and legal/LUT overlays. Capabilities an app lacks (sharing, motion, account,
cache, diagnostics, legal) are absent optional sections; only View Assist and Display still take a
per-entry picture source. Legal pages come from one typed `MonitorLegalDocuments` value (bundled
text or a web page per page) shown by `MonitorLegalDocumentScreen`. SwiftUI uses its existing complete
`MonitorOperatorSettingsScreen` and the same lower `MonitorSettingsPage` primitive.

`MonitorSettingsPage` owns tab navigation, selected headings, session status/disconnect and
content scrolling. `MonitorSettingsTab` has stable Link, Sharing, View Assist, Controls,
Display, Storage and System identities. The host supplies brand text, connection values,
actions and typed section composition. SwiftUI includes keyboard insets; Compose's complete
settings owner applies safe-drawing insets. Sharing content follows the actual optional source.

The optional `tabSpacing` argument defaults to 6 points/dp, preserving existing
callers. Swift applies it to both orientations; Compose applies it to portrait
tabs and keeps its already joined landscape column. A host can supply zero
for joined edges in both orientations without replacing the page owner.
Pocket uses this policy; other current consumers keep their defaults.

Common `MonitorSettings` controls own row, help, switch, reset and card presentation.
`MonitorOperatorSafetySettings` and `MonitorPanelSettings` accept values/bindings and actions;
they never locate app storage or a camera session. Common sections continue to move here as
the actual consumers migrate. Integration panels and OS actions remain host composition.

`MonitorCacheSettings` takes the host's cache scope/help, current size, clearing state and
actions. It owns no files or transfers. `MonitorAppInformationSettings` takes app identity as
content; `MonitorProjectLegalSettings` takes document/navigation callbacks. Support/report
status and diagnostic rows use `MonitorSupportSettings` and `MonitorDiagnosticSettings`;
the host retains consent storage, reporting availability, queue operations and diagnostic IO.
`MonitorSettingsNumberField` shares bounded native numeric input with a Done action; action
pills and compact display switches use the same shared settings presentation.

`MonitorGimbalSettings`, `MonitorJoystickSettings` and `MonitorControllerSettings` own the
actual motion-control cards, native stepped sliders, choices and switches. Apps supply
bindings or current values/actions, supported ranges, optional head-tracking controls,
status text and feedback policy. Storage keys, stick command cancellation and integration
curve/size mapping remain in the app. No motion setting starts a camera command by itself.

`MonitorDisplaySections` owns typed Display cards, editor admission, visibility controls and
clean-view pins, including hosts without a separate capture-layout picker. `MonitorDisplaySettings`
composes it with a supplied capture choice and ordering. Editor sections retain compact grids;
control sections retain native help rows and pins while offline. Apps supply saved values,
eligibility and reset actions. Neither component creates a capture-mode preference or a namespace.

`MonitorViewAssistSettings` owns the ordered common assist cards, reset headers and measured
column admission. Sections accept finite typed common menus or their facts/actions; unsupported
tools are omitted and unavailable sections expose no editor or reset. Apps resolve source
calibration and supply their existing saved bindings and feedback. Optional input/orientation
controls likewise receive real supported values and actions rather than creating app preferences.

`MonitorExposureMeterSettings` and `MonitorLookSettings` own the common EV Meter and LUT
cards in both implementations. The app supplies the current operator choice, its exercised
exposure-reading help, selected-look text and existing toggle/picker actions. Camera readings,
catalog selection, persistence and platform feedback stay with their current owners; presenting
either card sends no camera command.

`MonitorLinkHealthScale` renders a supplied known score using the existing common link
bands. The source still interprets delivery observations; the view never reads a transport.

`MonitorAccountSettings` renders known local configuration, connection and sign-in state
on both platforms, with optional sign-in/sign-out actions. Apps keep credentials, OAuth,
requests and service-specific copy. Missing actions stay absent.

`MonitorFeedSharingSettings` owns the actual Apple relay-host settings rows: share switch,
Wi-Fi-code action (absent when the app passes none, for cameras whose watchers must not join
the camera's network), passcode field, control requests and supplied priority choices. The app
keeps relay admission/lifetime, borrowed-camera policy, keychain writes and Wi-Fi-sheet
presentation. Android's deployed settings sources retain Coming soon content; the configured
source renders its supplied sharing values and admitted peer actions through common rows.
Generated session settings currently omit Sharing. This source distinction
does not imply relay or account availability where the host supplies none.

## Import rules

- Native scope plots consume portable Media values for histogram/traffic readings, transfer
  and axis anchors. They do not subscribe to a native bus, own a decoder or locate an app model.
- `MonitorWaveformScopePlot`, the parade mode and `MonitorVectorscopeScopePlot` own trace,
  guide and graticule composition. Swift uses retained Metal vertex/texture rings with a
  Canvas fallback; Compose uses retained raster layers and HWUI image drawing. Apps bind
  source bundles and operator settings. The source provides its measured clip/table values.
- Metal scopes apply an injected display action to their actual native view and retain the
  returned `MonitorScopeDisplayOptions`. Drawing reads that per-view snapshot; it never
  reaches a native runtime or an app's mutable display switch. MetalKit and `os` are system
  frameworks used by this implementation, with no new package dependency.
- Existing trace baselines stay explicit inputs: at 100% operator brightness the Swift
  waveform/parade multiplier is 0.25; Compose waveform is 0.25 and parade is 1.0. This
  inherited platform difference is preserved until physical qualification. Both vectorscopes
  use 1.0. New empty trace products and zero intensity clear displayed scope output.
- `MonitorMovableScopePanel` owns body drag, stationary hold and corner resize. Storage
  and camera sources stay outside the view. Swift receives an immutable panel layout and
  typed move actions; Compose receives normalized center values and commits at release.
  Cancelled input clears transient movement without saving, including lock and geometry
  changes. `MonitorScopeStoredCenter` retains the existing fraction field names, with
  independent portrait and landscape storage selected by the app.
- Native resize targets preserve their existing platform sizing: Apple uses a 56 point
  target; Compose adapts its 90 dp target down to a 44 dp minimum on small panels. The
  visible corner is 14 points/dp with a 2 point/dp exterior gap and 12 point/dp bottom
  overhang. Placement fits the body between fixed controls without rewriting storage.
  Compose options anchors are expressed in dp relative to an injected canvas origin;
  Apple options anchors use the panel canvas coordinates.
- `MonitorAssistTool` owns the current 18 tool labels, configuration availability
  and glyph mapping; `MonitorAssistToolGlyph` renders the actual native artwork.
  Sources retain capability filtering, saved selection and toolbar order. Legacy
  Apple playback/magnification IDs stay in the app compatibility adapter. Existing
  default platform grouping is preserved: Apple groups desqueeze with mirror;
  Compose groups desqueeze with framing and gives mirror its own group. Stored
  identities retain their original platform spelling, including Compose DESQ and
  Apple DE-SQ; this is a presentation catalog, not a persistence migration.
- `MonitorScopeTraceMenu`, `MonitorVectorscopeMenu`, `MonitorHistogramMenu` and
  `MonitorCrushClipMenu` own the actual scope tuning rows. Hosts bind typed current
  values and provide existing selection feedback and explanatory content; the views
  read no preference namespace, sampler or camera model. Swift retains its native
  stepped slider, while Compose retains its 44 dp pill slider with horizontal input
  and parent scrolling. Color cells retain 44 point/dp targets, and fraction controls
  speak the full stop value while drawing the compact glyph. Shared settings primitives
  also serve the full operator page; inspector tuning adds no duplicate row owner.
- `MonitorNDFilterChip` displays a portable Media suggestion and operator notation,
  never a camera command. The actual histogram calculation lives in Media and
  returns absent for an empty/nonfinite measurement, separately from known zero.
  Apps inject their existing no-filter and missing-picture label content. Swift
  retains its rounded system-font capsule and accessibility detail; Compose
  retains the fitted plain panel text and existing typography. This inherited
  native drawing difference remains explicit pending physical qualification.
- `MonitorLevelOverlay` owns actual strip/bubble/caption composition and visible-feed
  placement. Apps resolve attitude freshness and picture-axis flips into an immutable
  `MonitorLevelDisplay`; the shared view owns no sampling clock. Geometry is in
  points on Swift and dp on Compose. Unavailable readings draw bare bands and an
  explicit caption, never a green zero. Existing typography/accessibility casing
  and native bubble/gauge drawing remain platform-specific donor behavior.
- `MonitorAudioMeter` is the actual stereo level/held-peak drawing on both native
  platforms. Source adapters supply dBFS readings; the view does not advance a
  decay clock or read telemetry. Orientation identities retain their stored labels.
  Swift preserves its graduated zones, fixed 10 point tracks, 10 point label reserve
  and Foundation readout rounding; Compose preserves its whole-bar zone color,
  fitted tracks, 12 dp label reserve and Kotlin rounding. These inherited drawing
  differences remain explicit pending physical qualification.
- `MonitorFalseColorReference` renders a resolved source key: typed RGB/fraction
  segments, labeled axis markers and a subtitle. Source adapters select the look,
  ceiling and scale before constructing `MonitorFalseColorReferenceValues`; the
  view never selects a protocol mode or calibration. Kotlin copies caller lists
  at construction so reusing them for a successor cannot rewrite a retained key.
  Gaps keep the donor neutral background and empty successors remove old bands.
  Swift retains its existing inspector variant and gradient gap fill; Compose
  retains its existing full key and flat gap fill. No new inspector variant is
  introduced where there was no actual donor consumer.
- `MonitorTrafficLightsMeter` consumes an immutable Media RGB reading and owns the
  goal-post columns, upper clip/lower crush lamps and center-anchored single-sided
  fill. Its display geometry and accessibility descriptions share one owner;
  sampling, compensation and source calibration stay outside the UI. Existing
  Swift width spreading and Compose native Canvas typography remain explicit
  platform behavior. Empty/neutral successors remove the previous colored bars.
- `MonitorCommandDashboard` and `MonitorCommandGrid` are the command dashboard (DISP 3) on
  both platforms, with the same names, values (`MonitorCommandTile<Kind, Request>`,
  `MonitorCommandSection`, `MonitorCommandHealth`), constants (three columns, 9 point/dp
  spacing, 44 minimum and 76 portrait row, 42/44 side cells, 12 corner radius), order math
  (`monitorCommandTileOrder`, `moveMonitorCommandTile`, in MonitorPresentation on Swift) and
  reorder rules: a long press lifts only a painted tile that has a kind, the held tile follows
  the finger inside the grid, a move is reported as (kind, slot) only when the slot changes,
  and a drop or cancel keeps taps from opening a tile for 150 ms
  (`MonitorCommandGridDrag`). Read-only and locked tiles stay reorderable. Apps supply tile
  kinds, values, requests and the trailing health chip; `MonitorCommandTileOrderPreferences`
  (appkit) stores the order under the app's key. Swift keeps the donor iOS drawing: rows cap
  at 150 points on a tablet with a 34 point value, values shrink by `minimumScaleFactor`
  instead of Compose's length steps, read-only values keep the text color (Compose mutes them),
  the health strip spans the full width above grid and side column (Compose puts it over the
  grid only) and the side column is 27 percent of the picture, at least 160 points (Compose
  weights 2.35 to 0.85), with the masked fade and "More" hint. Swift spells accessibility as
  label, value and hint; Compose as one content description.
  The dashboard's hero owns the record chip and the timecode and its tiles the format, so
  command mode drops the live header's record chip, clock and format readouts
  (`MonitorCommandDashboardLayout.header`, both platforms). Landscape and phone portrait have
  no header at all and the dashboard moves up into its place: in landscape the gauge column
  keeps the link and the batteries and the health strip storage; in phone portrait the
  telemetry row keeps all three. A portrait tablet has no telemetry row and no health strip, so
  its header keeps storage and the link alone.
- `MonitorFeedGrid`, `MonitorFeedCrosshair` and `MonitorAspectGuideFrames` own native
  picture framing. Guide labels and enum identities retain the persisted app values;
  apps keep selection, storage and source geometry. The guide mask dims only the
  picture area outside the union of selected frames, including crossing wide and
  tall guides. Native rendered tests cover their independent arms and the exterior.
- Swift also owns the donor's `MonitorFeedComparisonMarks`, with injected original
  and processed labels. Compose had no corresponding comparison-label overlay;
  this inherited platform difference remains explicit rather than adding an
  unexercised view. Existing platform caption placement and font choices are retained.
- `MonitorTrackingLayer` draws resolved tracking brackets, focus marks and lock
  tags. Apps retain report selection, source-axis projection and command policy;
  the view receives only immutable picture coordinates, colors and line widths.
  Empty successors clear the previous marks. `MonitorTrackingCancelButton` keeps
  the native 28 point/dp disc inside its 44 point/dp input target. Swift retains
  capped corner radii and shadows; Compose retains its existing pixel-radius
  calculation and Canvas tag layout. These inherited native differences remain
  explicit pending physical qualification. Compose `monitorChromeClickable`
  owns press/tap/hold input and animation, with feedback supplied by the host.
- `MonitorFocusMark` takes the camera-reported AF `area` (normalized; the mark takes
  its size and centre, with a corner of at most 7 points/dp) or draws the standard
  square, and traces the hold-to-lock progress in the accent until the lock engages
  (`MonitorTrackingGeometry.focusBoxFrame` and `focusCornerRadius`, same cases on both
  platforms). `MonitorTrackingLayer` also draws further reported areas without tags.
  `MonitorOperatorFocusLayer` (OpenCineCameraControls, both platforms) resolves the
  mark's ink with `MonitorOperatorFocusInk` (AE lock, camera-confirmed, unconfirmed,
  accent) and draws group-AF areas in the confirmed green; Z feeds it on both shells.
- `MonitorOperatorLivePicture.notice` (`MonitorOperatorPictureNotice`) puts a source's
  own words on the waiting plate's look (`plate`: notice, else waiting), on both
  platforms. `LadderSheet` takes `formats`, drawing the shared `CaptureFormatPicker`
  for a recording-format tab (`ladderFormatWrite` admits only ladder values), on both
  platforms.
- Compose quick previews keep the capture strip placed while hiding its readouts
  and accessibility. The existing gesture owner admits the held pointer and
  refuses sibling input; full bottom sheets still hide and disable the slot.
  SwiftUI already retains its capture slot through opacity changes. Physical
  pointer qualification remains separate from source and simulated checks.
- Assist menus now own the actual audio, ND notation, peaking, false-color, zebra,
  desqueeze, guide, grid, mirror and help assemblies. They reuse the shared settings
  controls and receive current values/bindings, action closures and host feedback.
  Source adapters resolve false-color keys and zebra readouts before constructing
  the menu; views choose no look, source calibration or command. Swift preserves
  native audio toggles, adaptive guide chips and its monitoring-axis zebra slider;
  Compose preserves row switches, wrapping guide chips and its converted editor
  axis. These existing native differences remain explicit pending physical checks.
- No dependency on `OpenPocketViewCore`, any vendor/camera package, or any app target.
- Shared views take focused values and action closures; they never reach an app model or
  camera session.
- Brand differences come in as theme values, never as brand conditionals in shared code.
- Enforced by `SharedUIRulesTests` (Swift) and `SharedUIRulesTest` (Kotlin): shared UI sources
  name no brand, product or app, and hold no mutable global outside a short allowlist (accent,
  HDR headroom, `MonitorIosParity` until it is removed).

Connection settings own the native transport/phase/network rows and read-only saved-camera
summaries. Apps provide interpreted values and explanatory content; missing networks stay
optional, and stable saved-camera identifiers retain each row's help state. Pairing, credentials,
transport health scoring and device-specific processing choices remain with their owners.

The common playback screen owns the fixed video canvas, transport, metadata/conform panels,
clean-view chrome and native zoom/scrub gestures. It takes immutable accepted item facts and
item/edit-token actions, with fixed native-picture, feed-assist, canvas-assist and tool positions.
Apps retain native factories, source calibration, audio, deletion and delivery transactions. The
picture stays mounted while controls, panels and orientation change. Kotlin retains the existing
separate native control window; the app supplies its platform back handler without a new package
edge. UI edit ownership is retired before calling the host, so a delayed cancellation cannot take
a successor edit on the same item. The existing playback owner decides seeking and resume policy.

## Checks

```sh
swift build && swift test --filter MonitorPresentationTests   # macOS
xcodebuild -scheme MonitorUI -destination 'generic/platform=iOS Simulator' build
xcodebuild test -scheme OpenCine-Package -destination <private simulator> -only-testing:MonitorUITests
python3 scripts/vendor-lucide-icons.py          # refresh pinned Lucide SVGs (iOS + Android)
```

Playback labels and values come from the Swift and Kotlin `MonitorPlaybackCopy` twins,
bound to the same `Fixtures/playback-copy.tsv` vectors. The picture gesture well has a test tag
and no screen-reader action. The hide-controls hint is iOS-only; TalkBack supplies its own action hint.

The native confirmation-label contracts require a foreground application scene and mounted UIKit
controls. `scripts/ios-playback-label-hosted-test.py --simulator-id <private simulator> --derived-data
<scratch directory> --output <new evidence directory>` generates a developer-only SIMULATED host and
runs all three named contracts. It requires XcodeGen and an accessibility-enabled private simulator;
the caller owns simulator setup and cleanup. The iOS conformance-kit CI job runs this beside the
package-hosted walk tests. The generated host is never a package product or a camera app.

The three original methods keep the 900x420 transport fixture and both deletion contracts.
An attaching native UI reader supplies one guarded outside-popover event for each deletion;
the original fixture publishes observations and checks its actual callbacks and native disappearance
before teardown. Both readers must exit before simulator shutdown. Local admission requires the
external backing mount; GitHub CI checks its own filesystem, with the same 20 GiB storage floor.

`scripts/ios-playback-label-ci.py --output <new directory>` prepares the standard native UI
target from the same shared-screen host and guarded system-dismissal driver. Its explicit
`--run` mode belongs to a caller-owned GitHub CI simulator, records the actual app-authored
callback bytes and all twenty native predicates, and retains its private data and Products.
The `playback-native-ios` job follows the original three-case `kit-ios` gate. Both gates must
pass; the typed native counterpart cannot waive an original fixture failure. Local qualification
continues to use the separately reviewed lifecycle runner and retained evidence packets.

## License

Apache 2.0 ([LICENSE](../../LICENSE), [NOTICE](../../NOTICE)). Bundled fonts and icons:
[THIRD-PARTY-NOTICES.md](../../THIRD-PARTY-NOTICES.md).

Assist identities, scope modes/guide selections, audio orientation/readout, resolved false-color
reference values and the exact normalized-center Codable fields belong to Foundation-only
MonitorPresentation. MonitorUI keeps source-compatible public aliases plus native glyph/coordinate
extensions. Native CGRect/CGSize geometry remains UI-owned; Foundation is not widened with a
CoreGraphics import or retroactive conformances. Kotlin separates the same actual pure declarations
from native view files in its existing package; native APIs and persisted identifiers are unchanged.
The existing Swift Codable versus Android caller-owned codec and native absent-audio label/rounding
differences remain explicit in the mirrored value-contract scenarios.

Delivery composition lives in `MonitorMediaDeliveryPanel` on SwiftUI and Compose. Its mirrored
immutable value supplies destination eligibility, optional export controls, project or internet
service facts, and the footer action. Typed actions return to the host; the only view slot is
destination artwork. Missing controls stay absent. Hosts keep credentials, project requests,
network handoffs, file ownership, native sharing and export tasks. SwiftUI keeps the header and
footer visible while the content scrolls at constrained card heights. Compact progress receives
busy and known-progress visibility independently, so network switching can retain a reported
progress bar. Optional compact expansion is distinct from cancellation and
defaults to absent; expanded progress receives optional filename and destination
details plus typed Collapse/Cancel actions. Project labels prefer a supplied
choice ID match, then an optional known selected label without adding an
unlisted choice. The original four-argument Kotlin compact call with trailing
destination artwork remains supported. Actual Insta popup renders exercise both
overflow heights and busy progress; Nikon hosted UIKit actions exercise popup
admission, request values and progress controls at portrait and compact
landscape geometries. Physical delivery and Android input remain untested.

The expanded View Assist palette uses the same short toolbar labels on both platforms,
including PEAK, FALSE, WAVE, HISTO, VECTOR, LIGHTS and DE-SQ. Full tool names remain in
inspectors, settings and accessibility. Catalog cells scroll horizontally in landscape
and vertically in portrait; the collapsed favorites keep the common system-button size.
Expanded cells keep the collapsed square size (48 points in SwiftUI; 48 dp on phones
and 52 dp on tablets in Compose), with the same palette-sized icons and single-line
captions through the reveal.
