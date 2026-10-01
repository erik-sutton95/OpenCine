# OpenCineCore

Portable common contracts for the OpenCine camera monitor apps: identity, observations with
provenance, capability descriptors, camera state, the command lifecycle, monitoring-entry
composition and a small camera-session seam. Manufacturer integrations translate their
protocols into these values; shared UI and multicam read them without knowing which camera is
behind them.

Status: pre-release (plan work package CORE-01). No production app depends on it yet. Expect
interface changes driven by the first real adapter slices (CORE-02).

## Products

| Product | Contents | Use from |
|---|---|---|
| `OpenCineCore` | Value types and the `CameraSession` protocol. Foundation only. | Integrations, multicam, UI presentation, apps |
| `OpenCineCoreTestSupport` | Deterministic fakes (`FakeCameraSession` in DJI-like, Nikon-like and Luna-like configurations, picture-only and control-only entries) | Test targets only; never link into an app |
| `OpenCineMedia` | Portable media math: `.cube` parsing and interpolation, custom LUT index, LUT exposure compensation, published transfer curves, scope anchors and display scale, traffic lights, false-colour scales (Video, IRE, Limits, CineStop and the LOG/709 reading), zebra defaults, shutter angle, frame-rate sampling, feed framing. The encoded-unit seam: `EncodedVideoUnit` (stream, generation, codec, Annex-B or JPEG payload, random access, parameter sets, host arrival, optional PTS and format), HEVC/AVC NAL math (`Hevc`, `Avc`, `LiveVideo`), decoder parameter-set policy (`EncoderPresentPath`), present policy (`FeedPresentPolicy`, `SerialSessionGate`, `ExtraMirrorHold`), `DeliveryCadence`, and the Apple-only scope tap `LiveFrameTap`. Foundation plus OpenCineCore; builds with the Swift Android SDK. | Integrations, app cores, Android JNI facades |
| `OpenCineFrameIO` | Optional Frame.io delivery: v4 request planning (`FrameioAPI`), OAuth PKCE primitives and IMS token requests (`FrameioOAuth`, `PKCE`), response models, the upload workflow with injected transport, token storage, clock and pause (`FrameioClient`), batch results with history and cleanup reporting (`FrameioDelivery`, `FrameioDeliveryReport`), and an Apple `URLSession` transport. Foundation only (CryptoKit on Apple platforms). See [OpenCineFrameIO](#opencineframeio). | Apps that deliver to Frame.io; Android JNI facades |
| Android `com.opencapture.opencine:core` | Kotlin mirror of `OpenCineCore`; the fakes ship as its test fixtures. See [Android](#android). | Android integrations and apps |
| Android `com.opencapture.opencine:media` | Kotlin side of the encoded-unit seam: `EncodedVideoUnit`, `Hevc`/`Avc`/`LiveVideo` NAL math, and the Android decoder's portable policy (`LiveAccessUnit`, `CompressedAccessUnitAdmission`, `DecoderRandomAccessHold`, `DecoderInputOwnership`, `DecoderErrorLifetime`, `EncoderPresentPath`, `LivePictureSps`, `LiveDecoderTuning`, `LiveHevcCodec`, `LivePipelineCadence`, `LiveViewPresentTiming`, `FeedPresentPolicy`). No Android framework: MediaCodec and Surface stay in the app. | Android apps |

## OpenCineMedia rules

- Pure functions and value types. No mutable global state: a test rejects `static var` and
  `nonisolated(unsafe)` in `Sources/OpenCineMedia`.
- Imports Foundation and OpenCineCore only. `LiveFrameTap` (CVPixelBuffer to BGRA8) is the one
  Apple-only helper and sits behind `#if canImport(CoreVideo)`. Platform decoders, sample buffers
  and surfaces stay in native runtimes; `EncodedVideoUnit` carries bytes and identity only.
- Vendor framing stays with the integration: a private marker NAL or a vendor live-view enable
  request is stripped or decided before units reach these helpers.
- No camera raw modes. `MonitorTransfer` names a published curve; mapping a camera's colour
  mode or a tap fingerprint to a curve belongs to the integration.
- Per-source inputs are parameters. The live clip ceiling (`clipByte`, measured per source by
  the integration), the operator's LOG/709 reading and the official look's grey-axis curve
  (`lookCurve`, derived from the integration's own cube) are passed in by the caller.
- Numbers are golden. Moving or refactoring must not change a test value; a changed look needs
  an explicit fixture review.
- The 8-bit, 256-bin scope axis is the qualified implementation. Richer formats get new
  descriptors, not a silent change to these functions.
- Renderer size policy stays with the app (`colorCube` caps at 64 for Core Image; OpenZCine
  resamples 65³ imports to 33³ with `resampled(to:)`).

## Import rules

- `OpenCineCore` imports only Foundation. It never imports UI, a manufacturer integration,
  Multicam or an app. Platform media types (`CVPixelBuffer`, `UIImage`, `Bitmap`, GPU textures)
  never appear in portable state.
- Shared code never chooses behavior from a manufacturer name or `IntegrationID`.
- `Tests/OpenCineCoreTests` enforces the import and brand-name rules on `Sources/OpenCineCore`.

## Model in one screen

- **Unknown is `nil`.** Every telemetry field is an `ObservedValue` (named so it never shadows
  Swift's Observation module, so `@Observable` files can import OpenCineCore) whose `value == nil` means
  unknown, never `false`, `0` or `""`. Observations carry origin (camera-reported,
  protocol-derived, image-estimated, clock-derived, operator-provided, unknown), timestamp,
  validity and optional precision. Freshness is computed against a caller-supplied `now`.
- **Capabilities have four layers:** support (in `CapabilitySnapshot`), value domain and access,
  current availability with a typed reason, and semantics (native or emulated, readback or
  acknowledgement only, qualification). Any change advances `CapabilityRevision`.
- **Settings use a reviewed sum type** (`SettingValue`) whose case implies its key: ISO ladder or
  bounded auto, shutter as native duration or native angle, aperture, exposure compensation,
  white balance, white balance tint (its own key, so a camera without tint lists it unsupported),
  rational frame rate, focus mode, zoom. `recording` and `focusPoint` are
  command-only controls.
- **Reported state is separate from requested state.** `RecordingState` is camera-reported only.
  Command progress lives in `CommandReceipt`, tracked by `OperationID`:
  `created > admitted > sent > accepted > awaitingObservation > confirmed`, or `rejected`,
  `failed` (`notApplied`, `notSent`, or `superseded` by a newer write to the same setting),
  `timedOut`, `outcomeUnknown`. `receipt(of:)` reads the current stage without waiting.
- **Recording uses explicit start and stop.** UI toggles resolve against a fresh snapshot first.
- **Admission is shared.** `CameraSnapshot.rejection(of:at:)` checks session, connection, control
  epoch, deadline, authority and lease, capability revision, support, access, availability and
  domain. Integrations add their own protocol rules after it.
- **Monitoring entries compose roles.** `MonitorEntryDescriptor` holds an optional picture, an
  optional camera session, telemetry and control authority; at least one role must exist.
- **`CameraSession`** offers a bounded latest-value snapshot feed and reliable outcomes. Its doc
  comment specifies buffering, cancellation and close semantics.
- **`MonitorLayoutCapabilities`** is a separate ten-field layout projection matching the UI's
  current `MonitorCapabilities`, derived from the richer model where Core has vocabulary.

## OpenCineFrameIO

Optional. A camera-only consumer never links it: depending on the `OpenCineCore` or
`OpenCineMedia` product compiles nothing from it, and it declares no package dependency, so
`swift package show-dependencies` for a Core-only consumer lists no remote packages. (SwiftPM
resolves every package dependency a manifest declares, even one only an unused product needs;
that is why PKCE takes an injected SHA-256 on non-Apple platforms instead of this package
depending on swift-crypto. An Android facade passes swift-crypto's SHA-256 from its own package.)

The app owns, and this product never names:

- OAuth presentation (`ASWebAuthenticationSession`, Custom Tabs), callback URL schemes and the
  Adobe client ID / redirect URI from its build configuration.
- Credential storage: `FrameioTokenStorage` is implemented by the app over its own keychain or
  keystore namespace (for example service `OpenPocketCine.frameio`). Sharing this package never
  shares a sign-in. `StoredFrameioToken` keeps the Codable shape the apps already stored.
- Upload destination preferences, media preparation (exports, LUT bake, sidecars) and history
  storage (`FrameioUploadHistory`).

### Network hops and camera claims

Every Frame.io byte, including token refresh and upload parts, goes through
`FrameioHTTPTransport.send`. That is the single place an app enforces route ownership:

1. While the phone's Wi-Fi is a camera access point, the transport refuses (throws) unless the
   operator approved an internet hop for this delivery.
2. Before starting a hop, the app asks whether leaving the current network would take a route
   from a live camera. With OpenCineMulticam, model the hop as a candidate
   `ResourceRequest(entry: <delivery entry>, device: nil, claims: [.infrastructureNetwork(<internet network>)])`
   and call `ResourceAdmission.reasons(admitting:alongside:budget:)` with the live members. Any
   `.wifiNetworkConflict` or `.accessPointTaken` reason means another camera owns the phone's
   Wi-Fi: show it to the operator and do not hop silently.
3. The hop's owner rejoins the camera when delivery ends, on every exit path (success, failure,
   cancellation).

This product deliberately does not depend on OpenCineMulticam or a reachability API; the app
composes them.

## Android

`Android/` is a standalone Gradle build with two plain Kotlin/JVM modules, `core`
(`com.opencapture.opencine:core`, `0.1.0-SNAPSHOT`) and `media` (`com.opencapture.opencine:media`,
moved from the Pocket/Insta apps; it depends on `core` and keeps the moved code's shape, so explicit
API mode is off there). It has no Android framework dependency, so
app modules depend on it directly and its tests run on the JVM. It mirrors `Sources/OpenCineCore`
type for type with the same semantics, and `FakeCameraSession`, the three fixture families,
`FakePictureSource` and `FakeEntries` are its test fixtures (package
`com.opencapture.opencine.core.testing`). Kotlin 2.4.20, kotlinx-coroutines 1.11.0 and a JVM 17
target match the OpenPocketCine catalog; warnings are errors and explicit API mode is on.

```sh
cd Android && ./gradlew build   # JDK 17 or newer
```

Consume it from an app on a candidate branch with a composite build (path from `Apps/Android`
to a sibling checkout). Name the included build: OpenCineUI's Gradle build also lives in a
directory called `Android`, and two included builds cannot share a name.

```kotlin
// settings.gradle.kts
includeBuild("../../../OpenCineCore/Android") {
    name = "opencinecore"
    dependencySubstitution {
        substitute(module("com.opencapture.opencine:core")).using(project(":core"))
        substitute(module("com.opencapture.opencine:media")).using(project(":media"))
    }
}

// module build.gradle.kts
dependencies {
    implementation("com.opencapture.opencine:core:0.1.0-SNAPSHOT")
    testImplementation(testFixtures("com.opencapture.opencine:core:0.1.0-SNAPSHOT"))
}
```

Once published, drop `includeBuild` and use the Maven coordinate
`com.opencapture.opencine:core:<version>` (plus `testFixtures(...)` for the fakes); the group may
move to the verified Maven Central namespace at publish time. Local multi-repo work then becomes
an opt-in `includeBuild` behind an untracked property.

### Kotlin mapping

Same names and semantics, in Kotlin idiom. Where they differ:

- Each ID is its own `@JvmInline value class` (Swift: generic `Identifier<Kind>` and
  `Counter<Kind>`). Counters hold a `Long` (Swift `UInt64`).
- Cases without payload are `enum class` with `UPPER_SNAKE` constants; cases with payload are a
  `sealed interface` of `data object` and `data class`. Struct mutation is `copy(...)`.
- `ObservedValue` is covariant: `ObservedValue.unknown` is an `ObservedValue<Nothing>` assignable to any
  `ObservedValue<T>`, and its private constructor keeps a null value exclusive to it. Durations are
  `kotlin.time.Duration`; `MonotonicInstant.zero` is `MonotonicInstant.ZERO`.
- The feed is `val snapshots: StateFlow<CameraSnapshot>` (Swift `snapshots()` returning a
  `.bufferingNewest(1)` stream). Same latest-value conflation; `.value` replaces
  `currentSnapshot()`. A `StateFlow` never completes, so `close` leaves the final `Disconnected`
  snapshot in place instead of finishing streams; collectors end with their coroutine scope.
- Cancelling an `outcome(operation)` wait throws `CancellationException` in the waiter instead of
  returning the unfinished receipt. As in Swift, the operation itself is never affected.
  `receipt(operation)` (required on both, no default) does not suspend (Swift: `async`, because
  sessions are actors), so a confined owner or Compose reads it directly.
- `closeNow(reason)` is a Kotlin-only, non-suspending form of `close` for callers that cannot
  suspend (Compose `onDispose`). It schedules the same idempotent close on the session's scope.
- `MonitorEntryDescriptor.validate()` (typed throws) is `validationError(): MonitorEntryError?`.
  `rejection(of:at:)`, `support(of:)` and `value(of:)` are `rejection(command, now)`,
  `support(key)` and `value(key)`.
- No serialization: Swift's `Codable` has no Kotlin counterpart until a consumer persists or sends
  these values (then add kotlinx.serialization). A zero `Rational` denominator throws
  `IllegalArgumentException` at construction.
- Fakes: raw modes are `Int` (Swift `UInt8`), `FakeDevice.settings` is a map, and the fake is
  confined to one thread instead of being an actor.

### Test mapping

Scenarios are action sequences, so shared JSON fixtures would need an interpreter on both sides.
The suites are mirrored by name instead; change a contract and its mirrored test in Swift and
Kotlin together.

| Swift (`Tests/OpenCineCoreTests`) | Kotlin (`Android/core/src/test`) |
|---|---|
| `Conformance` "1." to "15." (20 tests, 11, 12 and 15 disabled) | `ConformanceTest` `01` to `15`, same titles (11, 12 and 15 `@Ignore`) |
| `Values` (6 tests) | `ValuesTest`, same method names |
| `Entries.everyEntryNeedsARole` | `EntriesTest.everyEntryNeedsARole` |
| `LayoutProjection.projectsWritableSectionsAndCarriesTheRest` | `LayoutProjectionTest`, same name |
| `Feeds` (3 tests) | `FeedsTest`, same method names |
| `Portability.coreImportsOnlyFoundationAndNamesNoManufacturer` | `PortabilityTest.coreImportsOnlyStdlibAndCoroutinesAndNamesNoManufacturer` |
| `Portability.portableStateHoldsNoNativeFrameOrObject` | Not ported: the Kotlin import rule (only `kotlin.*`, `kotlinx.coroutines.flow.*` and `java.util.UUID`) keeps platform types out |
| `GroupTargets.strictAndEligibleSubsetFromAdmission` | `GroupTargetsTest`, same name |

Parameterized Swift scenarios run each fixture family inside one JUnit test.

Byte-level media math shares data instead: `Fixtures/live-video-nal-vectors.tsv` is generated by
Swift `LiveVideoNalVectorTests` (which also checks it is current) and replayed by Kotlin
`LiveVideoNalVectorTest`. `EncodedVideoUnitTests` mirrors to `EncodedVideoUnitTest` by name.

## Development

```sh
swift build
swift test
cd Android && ./gradlew build
```

The package uses Swift 6 language mode (complete concurrency checking). Platforms: iOS 17,
macOS 13, watchOS 10.

## License

Apache License 2.0. See `LICENSE` and `NOTICE`.
