# OpenCineInsta360 agent guide

- Build and test: `swift build && swift test` (Swift 6 language mode, XCTest). Also build the iOS
  device slice: `xcodebuild -scheme Insta360Apple -destination 'generic/platform=iOS'
  CODE_SIGNING_ALLOWED=NO build` (the NEHotspotConfiguration branch compiles only there).
- Depends only on `../OpenCineCore` (pinned in `opencine-pins.txt`). Never modify Core from here:
  propose Core changes to its owner, then bump the pin.
- No UI, no app types, no brand strings. Anything an app names (keychain service, app name in
  messages, log prefix) goes through `LunaIntegrationConfiguration`. Never change the default
  keychain service: OpenInstaCine's saved credentials depend on it.
- Nothing process-wide: every `LunaCameraBackend` owns its link, session, store and callbacks.
  The single camera access point address in `LunaWiFi` is the one documented exception.
- Camera commands and reported state go only through `LunaCameraSession` (OpenCineCore). Never
  add a second command path to `CameraBackend`.
- Settle/readback strategy stays here; a write the camera accepts without storing is not success.
- Wire behavior changes need a physical Luna Ultra check through the consuming app.
- Keep `Sources/CKcp/LICENSE` and THIRD-PARTY-NOTICES.md with the C code.
- Never use the em dash character in code, comments, docs or commit messages.
- Commits: no co-author trailers.
