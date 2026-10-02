# OpenCineUI

Shared UI 2.0 design system. SwiftPM products `MonitorPresentation` and `MonitorUI`;
Compose module under `Android/monitor-ui`. Read [README.md](README.md) first.

## Hard rules

- Never import a camera protocol core (`OpenPocketViewCore`, ...), vendor package or app.
- Views take values and actions. No brand conditionals; brand variation is a theme value
  (`MonitorTheme.accentRGB`).
- Keep SwiftUI and Compose behavior in step. A fix on one platform lands on both or is
  recorded as an exception.
- New fonts or icons carry their license file next to the asset and a section in
  `THIRD-PARTY-NOTICES.md`. Lucide icons only through `scripts/vendor-lucide-icons.py`.
- Consumers pin this package; a change here is not live in an app until that app's pin moves
  and the app is verified (operator-visible UI on a physical device).
- Conventional Commits. No em dashes.

## Verification

- `swift build && swift test` (macOS).
- `xcodebuild -scheme MonitorUI -destination 'generic/platform=iOS Simulator' build`.
- Build at least one consuming app against the change before calling it done.
