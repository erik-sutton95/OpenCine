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

Resources load through `Bundle.module`; consumers copy no fonts or icons and add no
`Info.plist` font entries.

## Operator settings

`MonitorSettingsPage` owns tab navigation, selected headings, session status/disconnect and
content scrolling. `MonitorSettingsTab` has stable Link, Sharing, View Assist, Controls,
Display, Storage and System identities. The host supplies brand text, connection values,
actions and typed section composition. SwiftUI includes keyboard insets; Compose uses the
host's window insets. Android sharing currently retains its existing placeholder.

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

`MonitorLinkHealthScale` renders a supplied known score using the existing common link
bands. The source still interprets delivery observations; the view never reads a transport.

`MonitorAccountSettings` renders known local configuration, connection and sign-in state
on both platforms, with optional sign-in/sign-out actions. Apps keep credentials, OAuth,
requests and service-specific copy. Missing actions stay absent.

`MonitorFeedSharingSettings` owns the actual Apple relay-host settings rows: share switch,
Wi-Fi-code action, passcode field, control requests and supplied priority choices. The app
keeps relay admission/lifetime, borrowed-camera policy, keychain writes and Wi-Fi-sheet
presentation. This is an explicit platform exception: Android currently has no implemented
feed-sharing settings and retains its existing Coming soon content. No Android relay or
account functionality is implied by the shared presentation.

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

## Checks

```sh
swift build && swift test --filter MonitorPresentationTests   # macOS
xcodebuild -scheme MonitorUI -destination 'generic/platform=iOS Simulator' build
python3 scripts/vendor-lucide-icons.py          # refresh pinned Lucide SVGs (iOS + Android)
```

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
