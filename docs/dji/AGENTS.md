# OpenCineDJI agent guide

- Build and test: `swift build && swift test` (Swift 6 mode, Swift Testing). Needs the sibling
  `../OpenCineCore` at the SHA in `opencine-pins.txt` (`scripts/checkout-opencine.sh`).
- Imports Foundation and OpenCineMedia only. Never import UI frameworks, OpenCineUI or app code;
  apps compose this package, never the reverse.
- Never modify OpenCineCore from here: propose changes to its owner, then bump the pin here and in
  every consumer.
- Behavior changes need the consumer checks too: OpenPocketCine `swift test`, iOS build-for-testing
  and `just android-check` against this checkout (its Android facade links this module).
- Never use the em dash character in new code, comments, docs or commit messages (moved sources
  predate the rule; leave them unless editing the line).
- Commits: no co-author trailers.
