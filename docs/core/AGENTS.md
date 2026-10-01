# OpenCineCore agent guide

- Build and test: `swift build && swift test` (Swift 6 mode, Swift Testing).
- Android: `cd Android && ./gradlew build` (JDK 17+). `core` is plain Kotlin/JVM and mirrors
  `Sources/OpenCineCore`; the fakes are its test fixtures. Change a contract and its mirrored
  test in Swift and Kotlin in the same commit (README "Test mapping").
- `Sources/OpenCineCore` imports Foundation only and names no camera manufacturer; a test
  enforces both. Never import UI, an integration, Multicam or an app.
- Value types for descriptions, snapshots, settings, observations and results. Add a protocol
  only where implementations actually vary. No DI framework, no plugin registry.
- Unknown is `nil` in an `Observation`, never `false`, `0` or `""`.
- Grow the setting vocabulary only for a real adapter use case, with a test.
- Conformance scenarios (`Tests/OpenCineCoreTests/ConformanceTests.swift`) run through one harness
  for every fixture family and must not branch on the family.
- Fakes live in `OpenCineCoreTestSupport` and run on a manual clock; tests never sleep.
- Never use the em dash character in code, comments, docs or commit messages.
- Commits: no co-author trailers.
