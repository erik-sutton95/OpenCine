# OpenCineUI

The shared OpenCine UI 2.0 design system: presentation policy and native monitor
screens used by the OpenCapture camera apps (OpenPocketCine, OpenInstaCine, OpenZCine).

## Products

| Product | What | Platforms |
| --- | --- | --- |
| `MonitorPresentation` | Foundation-only layout, capability gates, selection and display values. No camera I/O. | iOS, macOS, watchOS |
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
Bluetooth`; OpenZCine passes `on this network`). Android's brand inputs are
`MonitorPalette.accent` and the transitional `MonitorIosParity.enabled`
(see [Android/monitor-ui/README.md](../../Android/monitor-ui/README.md)).

Resources load through `Bundle.module`; consumers copy no fonts or icons and add no
`Info.plist` font entries.

## Import rules

- No dependency on `OpenPocketViewCore`, any vendor/camera package, or any app target.
- Shared views take focused values and action closures; they never reach an app model or
  camera session.
- Brand differences come in as theme values, never as brand conditionals in shared code.
- Enforced by `SharedUIRulesTests` (Swift) and `SharedUIRulesTest` (Kotlin): shared UI sources
  name no brand, product or app, and hold no mutable global outside a short allowlist (accent,
  HDR headroom, `MonitorIosParity` until it is removed).

## Checks

```sh
swift build && swift test --filter MonitorPresentationTests   # macOS
xcodebuild -scheme MonitorUI -destination 'generic/platform=iOS Simulator' build
python3 scripts/vendor-lucide-icons.py          # refresh pinned Lucide SVGs (iOS + Android)
```

## License

Apache 2.0 ([LICENSE](../../LICENSE), [NOTICE](../../NOTICE)). Bundled fonts and icons:
[THIRD-PARTY-NOTICES.md](../../THIRD-PARTY-NOTICES.md).
