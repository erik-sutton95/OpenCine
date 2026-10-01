# OpenCineCore agent guide

- Build and test: `swift build && swift test` (Swift 6 mode, Swift Testing).
- Android: `cd Android && ./gradlew build` (JDK 17+). `core` is plain Kotlin/JVM and mirrors
  `Sources/OpenCineCore`; the fakes are its test fixtures. Change a contract and its mirrored
  test in Swift and Kotlin in the same commit (README "Test mapping").
- Android `media` is plain Kotlin/JVM: the decoder policy and NAL math the apps' MediaCodec path
  uses. No `android.*` there. `Fixtures/live-video-nal-vectors.tsv` pins Swift and Kotlin `LiveVideo`
  to the same answers; regenerate with `OPENCINE_WRITE_FIXTURES=1 swift test --filter
  LiveVideoNalVectorTests`, never by hand.
- `Sources/OpenCineCore` imports Foundation only and names no camera manufacturer; a test
  enforces both. Never import UI, an integration, Multicam or an app.
- `Sources/OpenCineMedia` imports Foundation only, holds no mutable global state and takes no
  camera raw mode; a test enforces it. Per-source values (clip ceiling, LOG/709 reading, look
  curve) are parameters. Existing test numbers are golden: never edit one to make a refactor pass.
- `Sources/OpenCineFrameIO` is optional: Foundation only (CryptoKit gated on Apple), no package
  dependency (SwiftPM would resolve it for every Core consumer), no global mutable state, and no
  app credential namespace, keychain, defaults or bundle lookup; a test enforces it. Transport,
  token storage, clock and pause are injected; tests never touch the network or sleep.
- Value types for descriptions, snapshots, settings, observations and results. Add a protocol
  only where implementations actually vary. No DI framework, no plugin registry.
- Unknown is `nil` in an `ObservedValue`, never `false`, `0` or `""`.
- Grow the setting vocabulary only for a real adapter use case, with a test.
- Conformance scenarios (`Tests/OpenCineCoreTests/ConformanceTests.swift`) run through one harness
  for every fixture family and must not branch on the family.
- Fakes live in `OpenCineCoreTestSupport` and run on a manual clock; tests never sleep.
- Never use the em dash character in code, comments, docs or commit messages.
- Commits: no co-author trailers.
