# OpenCineMulticam agent guide

- Build and test: `swift build && swift test` (Swift 6 mode, Swift Testing). CI also runs
  `swift build --build-tests -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`.
- Kotlin mirror: `cd Android && ./gradlew test` (JDK 17+, sibling `../OpenCineCore`). Change Swift
  and Kotlin together: every public type, semantic and scenario test exists on both sides with the
  same name (README "Kotlin mapping" lists the deliberate differences; update it with any new one).
- Depends only on `../OpenCineCore` (pinned in `opencine-pins.txt`). Never modify Core from here:
  propose Core changes to its owner, then bump the pin (Swift and Gradle both build against it).
- `Sources/OpenCineMulticam` imports Foundation and OpenCineCore only and names no manufacturer,
  UI framework or transport; `ImportRuleTests` enforces it on both sides (Kotlin: stdlib, coroutines and
  `com.opencapture.opencine.core` only).
- Value types and pure functions; the only async code submits and collects record commands. No
  runtime objects, timers, singletons, DI framework or plugin registry.
- Never add automatic compensation: no code path may stop or start a camera except the explicit
  direction of a plan the operator approved. Closing or removing never sends a command.
- App limits (qualified camera count, freshness windows, recovery limits) are parameters, never
  engine constants.
- Tests use `OpenCineCoreTestSupport` fakes (Kotlin: Core's `testFixtures`) on manual clocks; tests
  never sleep.
- Never use the em dash character in code, comments, docs or commit messages.
- Commits: no co-author trailers.
