# OpenCineNikon agent guide

- Build and test: `swift build && swift test` (Swift 6 mode, Swift Testing). Needs the sibling
  `../OpenCineCore` at the SHA in `opencine-pins.txt` (`scripts/checkout-opencine.sh`).
- Imports Foundation and OpenCineCore only (`ImportRuleTests`). Never import UI frameworks,
  OpenCineUI or app code; apps compose this package, never the reverse.
- Never modify OpenCineCore from here: propose changes to its owner, then bump the pin here and in
  every consumer.
- Behavior changes need the consumer checks too: OpenZCine `swift test`, iOS build-for-testing and
  `./gradlew test assembleDebug` with Swift core staging against this checkout (its Android
  facade links this module through `OpenZCineCore`).
- Passive discovery and the per-operation admission rules (record needs live view; settings do
  not) are product behavior: change them only with a hardware-qualified reason.
- Never use the em dash character in new code, comments, docs or commit messages (moved sources
  predate the rule; leave them unless editing the line).
- Commits: no co-author trailers.
