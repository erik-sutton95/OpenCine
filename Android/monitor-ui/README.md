# Android monitor UI engine

`:monitor-ui` owns native Compose presentation shared by camera apps. It has no
camera SDK, discovery, connection, media transfer, decoder, or app dependency.
App shells (OpenPocketCine first) depend on this module and adapt existing state
and commands into display values, capabilities, thumbnail content, and callbacks.

Extracted from OpenPocketCine `Apps/Android/monitor-ui` at 27b15028, with
OpenInstaCine's `MonitorTheme.kt` (settable `MonitorPalette.accent`, default
Pocket blue `0xFF00A3E0`). A brand shell assigns `accent` once before building
any view.

OpenZCine's engine-port copy (ef38a264) added `MonitorCardColumns` (port of iOS
`MonitorCardColumns`) and four Android fixes that match the shared iOS look:
compositor-tone unsampled glass, iOS media tags (`MonitorClipValue.sourceTint`),
uppercased page kickers, and the pairing rail back button with a centred portrait
footer. Those four change current Pocket/Insta Android rendering, so they sit
behind `MonitorIosParity.enabled` (default `false`). OpenZCine sets it to `true`
next to `accent`. Flip the default and delete the switch once Pocket and Insta
accept the iOS look.

## Build and consume

`Android/` is a standalone Gradle build. Coordinate:
`com.opencapture.opencine:monitor-ui:0.1.0-SNAPSHOT`, namespace
`com.opencapture.monitorui`.

```sh
cd Android
./gradlew :monitor-ui:testDebugUnitTest :monitor-ui:lint
# Instrumented tests (real pointer delivery and HWUI pixel readback of the shared components) on one device:
ANDROID_SERIAL=<device> ./gradlew :monitor-ui:connectedDebugAndroidTest
```

An app includes the platform build from a sibling OpenCine checkout and substitutes the
coordinate (Gradle composite build; one named include serves every OpenCine module):

```kotlin
// settings.gradle.kts
includeBuild("../../../OpenCine/Android") {
    name = "opencine"
    dependencySubstitution {
        substitute(module("com.opencapture.opencine:monitor-ui")).using(project(":monitor-ui"))
    }
}
// app/build.gradle.kts
implementation("com.opencapture.opencine:monitor-ui")
```

Consumers keep the same AGP, Kotlin and Compose BOM versions as
`Android/gradle/libs.versions.toml`. `MonitorIconCatalogTest` compares the Android
SVGs byte for byte with `Sources/MonitorUI/Resources/Icons` in this repository.

## Assets and licenses

| Asset | Path | Source | License |
| --- | --- | --- | --- |
| Lucide HUD icons (SVG + `opc_lucide_*` VectorDrawables) | `src/main/assets/icons/lucide/`, `src/main/res/drawable/opc_lucide_*.xml` | <https://github.com/lucide-icons/lucide> at the commit in `SOURCE.txt` | ISC; Feather-derived glyphs also MIT (`LICENSE.txt`) |
| View Assist glyphs (`monitor_assist_*`) | `src/main/assets/icons/assist/`, `src/main/res/drawable/monitor_assist_*.xml` | Approved Field Monitor design, Tabler-derived paths | MIT (`LICENSE-Tabler.txt`) |
| Sora typeface | `src/main/res/font/sora_*.ttf` | <https://github.com/sora-xor/sora-font> | SIL OFL 1.1 (`src/main/assets/OFL-Sora.txt`) |

The license files ship inside the AAR assets. The repository `NOTICE` and
`THIRD-PARTY-NOTICES.md` cover them; apps that bundle this module list them in
their own notices.

## Public presentation seams

- `MonitorPalette`, `MonitorTypography`, `MonitorIcon`, `MonitorAssistIcon`:
  common design tokens, Sora, vendored Lucide vectors, and the exact assist
  glyphs extracted from the approved design. Licenses ship with the assets.
- `MonitorCameraPage` / `MonitorCameraCard`: discovered and saved camera
  sections, responsive cards, identity and action slots.
- `MonitorPageScaffold` / `MonitorSettingsCard`: responsive page navigation and
  individual settings groups. A shell supplies content and supported actions.
- `MonitorCameraValues` / `MonitorQuickControl` / `MonitorValueDrum`:
  value labels, tap-to-open controls, transient hold/drag controls and horizontal
  perspective drums. Camera option lists and serialization remain in adapters.
- `MonitorAssistPalette`: generic tool identity, custom glyph slots, selected
  visibility and configuration actions. Live and playback visibility are
  separate values supplied by the caller. Injected usage seeds rank collapsed
  shortcuts; toggles and configuration actions increment their score, with
  catalog order breaking ties and no persistence beyond the palette lifetime.
- `MonitorClipValue`, `MonitorClipCard`, `MonitorCatalogHeader`,
  `MonitorCatalogGrid`, `MonitorSelectionTray`: complete clip presentation and
  toolbar/selection rendering. The app supplies bounded native thumbnails and
  real source/cache metadata; the library never opens a file or starts a job.
- `MonitorPlaybackHeader`, `MonitorPlaybackFooter`, `MonitorMetadataDrawer`:
  responsive chrome around the caller's existing native player. The footer
  stacks when the actual viewport cannot fit the centered transport and options.
- `MonitorZoomDisc`: a logarithmic edge-mounted half-disc, legal maximum,
  optical stops, captions and existing gesture callbacks supplied by the camera
  adapter. Its foreground slot keeps Record accessible above the dial.
- `MonitorImagePreview`: presentation of a caller-supplied bounded native image;
  no subscription, decoding or shader ownership in the UI module.
- `MonitorSlider`, `MonitorSwitchGraphic`, `MonitorOptionGroup`: lightweight
  native settings primitives with no captured backdrop or camera dependency.
- `MonitorTelemetry`: draw-only link (signal bars or feed fps), phone and camera
  battery gauges. The adapter supplies its delivery-health and battery readouts.
- `MonitorLayoutPolicy`: pure portrait frame/layout policy, preserving the
  actual source aspect. `MonitorCapabilities` defaults unsupported modules off.
- `MonitorCommandDashboard`: the command dashboard (three-column grid with long
  press drag reorder, health strip, side column). The adapter supplies typed
  `MonitorCommandTile<K, R>` values (`K` the persisted reorder identity, `R` its
  write request), the write state and a trailing health chip; `moveMonitorCommandTile`
  keeps an order complete and appkit `MonitorCommandTileOrderPreferences` stores
  it under the app's key. The SwiftUI twin is MonitorUI `MonitorCommandDashboard`
  (platform differences in `docs/ui/README.md`).

## Interaction and rendering contracts

Drums and transient quick controls keep a visual draft while dragging and emit
one value on release. Cancellation, a changed source context or authoritative
selection, locking, rotation, or a second pointer discards the draft. A stationary
hold never changes an unknown camera value. Value steps use 56 dp travel; native
Canvas and text measurement draw the 86 dp drum without a scrolling item tree.
Zoom deliberately streams through the existing camera zoom gesture adapter;
its existing coalescing and camera limits remain authoritative. A zoom gesture
ends when its window size, density, safe insets, layout direction or legal range
changes, so an old pointer cannot continue with a new angular origin.

Reusable controls have native button/adjustable semantics. Their callbacks are
intents, not permission to start discovery, subscribe to frames, or bypass camera
capabilities. Supplied scopes and thumbnails remain owned by their existing
renderers. All opaque pages use solid surfaces. Overlay tint is composited over
the picture; no screenshot or full-frame readback is used to synthesize blur.

## Validation and review fixture

Consuming apps and this library share the compile SDK version (API 37, in the
Gradle version catalog). API 37 satisfies the Compose AAR requirements; metadata
validation remains enabled so clean library packaging does not depend on stale
task outputs. Install it with `sdkmanager "platforms;android-37.0"`.

The module gate is the build command above. Each consuming app still runs its
own `assembleDebug`, unit tests and lint against this build.

OpenPocketCine's debug-only `MonitorPreviewActivity` mounts the production live chrome with
fixed readouts and capability flags. It starts no camera discovery, connection,
stream or decoder. For example, after installing the debug APK:

```sh
adb shell am start -n com.opencapture.openpocketcine/.MonitorPreviewActivity \
  --ef aspect 0.5625 --ef safeTop 44 --ez gimbal true --ez zoom true \
  --ez focus true --ez timecode true
```

Use actual window rotation and density when comparing phone/tablet layouts.
The fixture supports `aspect`, `safeTop`, `safeBottom`, `gimbal`, `zoom`, `focus`,
and `timecode` extras; these are review inputs, never production capabilities.
Physical Android camera validation is still required by the repository's
completion policy. Emulator validation does not exercise BLE or camera Wi-Fi.

## Deliberate rendering limits

Floating chrome GPU-blurs the existing 213×120 sampled tap (RenderEffect on
API 31+), not a SurfaceView screenshot or a second decoder. The sample follows
the picture (25 Hz when that tap is the only consumer) so the plates track
motion. Modal editors and drawers keep the same sampled material. Unsupported
API/hardware uses an explicit opaque fallback.
Scope inspectors reuse the existing latest-frame GPU scope tap, request only
the selected scope, and run at at most 5 Hz when no monitor scope is active.
Demand has an owner token and a live/playback domain, is released on disposal or
backgrounding, and keeps the existing busy, thermal and source-generation gates.
LUT, peaking, false-color and zebra previews reuse the existing raw scope tap,
fitted inside 213 × 120 pixels. One isolated EGL pbuffer worker runs the existing
production effect shaders; it adds no feed tap, decoder or Vulkan render pass.
The selected tool is enabled only in the preview plan. Admission is at most 5 Hz,
with one frame/job including pending main-thread delivery, and no frame queue.
Owner, live/playback domain and epoch checks discard stale output after tool,
options, source, window or lifecycle changes. A new source must be ready and
produce a freshly latched frame before it can provide a preview. Closing the
inspector releases its worker textures, FBOs, programs and EGL context.
