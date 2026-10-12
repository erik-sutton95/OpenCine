# Conformance scenarios

Each shared behavior has one scenario, written once in OpenCine and run by every app against its
own production composition. On iOS the scenarios live in `Sources/OpenCineAppUITesting/Conformance/`;
an app adopts one with a subclass line in its UI test bundle:

```swift
final class GalleryRoundTrip: OpenCineAppUITesting.GalleryRoundTrip {}
```

On Android they live in `Android/app-ui-testing` (`androidTestImplementation`); the app's androidTest
source set declares one `ConformanceApp` (its launcher activity and profile) and subclasses each
scenario in its `conformance` package:

```kotlin
class GalleryRoundTrip : com.opencapture.opencine.appuitesting.GalleryRoundTrip(PocketConformance)
```

`ConformanceCoverageTests` / `ConformanceCoverage` (adopted the same way) fails when a bundle leaves
a scenario below out. Every Android scenario class carries the inherited `@Conformance` annotation.

## Rules

- **Real entry, fake sources.** A scenario launches the app (`XCUIApplication`; on Android the
  app's activity through `ActivityScenario`, never `setContent`) with a typed
  `ReviewLaunch` (`MonitorPresentation`, Kotlin twin in `monitor-ui`). The app's Debug review
  harness stages fake sources (generated clips, a fake camera) inside the production view tree; it
  never swaps the view tree for a replica.
- **Capabilities, not brands.** Each UI test bundle declares a `ConformanceProfile` (app name for
  evidence, the `MonitorCapabilities` its review body renders) from its principal class
  (`NSPrincipalClass`, conventionally `<bundle>.ConformanceApp`). A scenario skips only what the
  profile says the camera cannot do; a missing fixture or unstaged screen fails.
- **Checkpoints.** `checkpoint(_:)` asserts that every enabled `monitor.*` control outside a
  scrolling list lies inside the window and that no two hittable ones overlap (a mode that makes the
  rest inert, the chrome editor, checks only its own controls with `operable:`). The screenshot
  matrix also passes `safeArea: true`: no visible control may lie under what hides part of the screen
  (iOS: the sensor housing and the home indicator band of the simulator model; Android: the visible
  system bars and the display cutout's outline). The corners beside a sensor housing stay usable.
  The behavior scenarios leave layout to the matrix. Each checkpoint attaches a screenshot named
  `<app>-<device>-<orientation>-<scenario>-<checkpoint>` (device: the hardware model, for example
  `iPhone17,1`, or the Android class and width, for example `phone411dp`). Each failure message
  starts with that name.
- **Covered screens stay in the tree.** A screen under a page, player or panel keeps its
  controls in XCTest's tree with the same identifiers (hidden from VoiceOver, not from XCTest), and
  XCTest on iOS 26 can report a hidden SwiftUI control hittable. Act on `reachable(_:)` (the first
  hittable match) when an identifier can match a covered copy, and prove a hidden or covered
  control is out of reach with `assertOutOfReach(_:)` (a touch where it sits changes nothing), not
  with `isHittable`. The first failure of a test attaches the app's element tree (`failure-tree`).
- **Cancel contract.** Confirmations are cancelled with `dismissConfirmation(_:)`: the Cancel
  button when there is one, else a tap outside the popover. A presentation with neither fails.

## Staging contract (`ReviewLaunch`)

| Field | Wire key | Meaning |
| --- | --- | --- |
| screen | `OPV_UI_REVIEW_SCREEN` | `cameras`, `pair`, `live`, `media`, `playback`, `settings`, `chrome-edit` |
| state | `OPV_UI_REVIEW_STATE` | the app's cameras and pair page states |
| layout | `OPV_UI_REVIEW_MEDIA_LAYOUT` | `grid` or `list` gallery |
| mediaCount | `OPV_UI_REVIEW_MEDIA_COUNT` | staged clips, default 96 |
| source | `OPV_UI_REVIEW_MEDIA_SOURCE` | `local` (the phone's cache) or `camera` (a camera's card) |
| connected | `OPV_UI_REVIEW_CONNECTED` | `1` stages a connected camera session |
| settingsTab | `OPV_UI_REVIEW_SETTINGS_TAB` | `MonitorSettingsTab` raw value |
| commonControls | `OPV_UI_REVIEW_COMMON_CONTROLS` | `1` writable simulated controls, `0` read-only preview |
| meteredEV | `OPV_UI_REVIEW_METERED_EV` | the camera's metered exposure in EV, absent when it meters none |

`media` opens the gallery with the clips staged; `playback` also opens the first clip. Staged
clips are playable (`ReviewClip` in `OpenCineApple` writes the movie) and cached on the phone.

## Scenarios

| ID | Gate | Platforms | Checks |
| --- | --- | --- | --- |
| S1 `GalleryRoundTrip` | none | iOS, Android | Grid and list, portrait and landscape: after opening a clip and going back, the same clip is first at the same place and layout and category are unchanged. |
| S2 `ShareRoundTrip` | none | iOS, Android | The selection share keeps the gallery place, the selection and selection mode; the clip share keeps the same clip with Loop on; Back returns to the same place. |
| S3 `ConfirmationCancel` | `clipDelete` for the camera deletes | iOS, Android | Cancelling playback delete, gallery delete and Clear cache changes nothing (Android: with Cancel and with system Back). |
| S4 `ChromeEditReturn` | none | iOS, Android | Done in the chrome editor returns to Display settings with the section in view; closing Settings returns to the monitor; the edit persists. |
| S5 `AccessibilityTraversal` | none | iOS, Android | Every staged screen and a presented confirmation has a bounded tree whose `monitor.*` controls are labelled. Hosted tests walk trees with `HostedAccessibility` (`OpenCineHostedAccessibility`, self-tested in `OpenCineHostedAccessibilityTests`). |

| M `ScreenMatrix` | none | iOS, Android | Cameras, pairing, live, gallery, player and settings, each in light and dark, portrait and landscape: the checkpoint invariants and one screenshot per cell. The device cell (phone or tablet) is the destination the run picks. |

## Running

Each app runs its UI review scheme on a private simulator created by
`scripts/ios-private-simulator.py` (iPhone 16 Pro, accessibility enabled), for example
`just conformance-ios <udid>`, and its Android scenarios on a private emulator created by
`scripts/android-private-emulator.py` (`connectedDebugAndroidTest` filtered by the `@Conformance`
annotation). One destination at a time.

The screenshot matrix for all apps, phone and tablet, is one command per platform:
`scripts/screen-matrix.py ios --out <dir>` and `scripts/screen-matrix.py android --out <dir>`. Each
writes `cells/<cell>.png` and a report (`report.md`, `report.json`, `index.html`), and exits 1 when a
cell breaks an invariant or is not captured.
