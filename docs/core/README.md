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
| `OpenCineMedia` | Portable media math: `.cube` parsing and interpolation, custom LUT index, LUT exposure compensation, published transfer curves, scope anchors and display scale, traffic lights, false-colour scales (Video, IRE, Limits, CineStop and the LOG/709 reading), zebra defaults, shutter angle, frame-rate sampling, feed framing. Foundation only; builds with the Swift Android SDK. | Integrations, app cores, Android JNI facades |
| Android `com.opencapture.opencine:core` | Kotlin mirror of `OpenCineCore`; the fakes ship as its test fixtures. See [Android](#android). | Android integrations and apps |

## OpenCineMedia rules

- Pure functions and value types. No mutable global state: a test rejects `static var` and
  `nonisolated(unsafe)` in `Sources/OpenCineMedia`.
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

- **Unknown is `nil`.** Every telemetry field is an `Observation` whose `value == nil` means
  unknown, never `false`, `0` or `""`. Observations carry origin (camera-reported,
  protocol-derived, image-estimated, clock-derived, operator-provided, unknown), timestamp,
  validity and optional precision. Freshness is computed against a caller-supplied `now`.
- **Capabilities have four layers:** support (in `CapabilitySnapshot`), value domain and access,
  current availability with a typed reason, and semantics (native or emulated, readback or
  acknowledgement only, qualification). Any change advances `CapabilityRevision`.
- **Settings use a reviewed sum type** (`SettingValue`) whose case implies its key: ISO ladder or
  bounded auto, shutter as native duration or native angle, aperture, exposure compensation,
  white balance, rational frame rate, focus mode, zoom. `recording` and `focusPoint` are
  command-only controls.
- **Reported state is separate from requested state.** `RecordingState` is camera-reported only.
  Command progress lives in `CommandReceipt`, tracked by `OperationID`:
  `created > admitted > sent > accepted > awaitingObservation > confirmed`, or `rejected`,
  `failed`, `timedOut`, `outcomeUnknown`.
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

## Android

`Android/` is a standalone Gradle build with one plain Kotlin/JVM module, `core`
(`com.opencapture.opencine:core`, `0.1.0-SNAPSHOT`). It has no Android framework dependency, so
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
- `Observation` is covariant: `Observation.unknown` is an `Observation<Nothing>` assignable to any
  `Observation<T>`, and its private constructor keeps a null value exclusive to it. Durations are
  `kotlin.time.Duration`; `MonotonicInstant.zero` is `MonotonicInstant.ZERO`.
- The feed is `val snapshots: StateFlow<CameraSnapshot>` (Swift `snapshots()` returning a
  `.bufferingNewest(1)` stream). Same latest-value conflation; `.value` replaces
  `currentSnapshot()`. A `StateFlow` never completes, so `close` leaves the final `Disconnected`
  snapshot in place instead of finishing streams; collectors end with their coroutine scope.
- Cancelling an `outcome(operation)` wait throws `CancellationException` in the waiter instead of
  returning the unfinished receipt. As in Swift, the operation itself is never affected.
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
| `Conformance` "1." to "15." (19 tests, 11, 12 and 15 disabled) | `ConformanceTest` `01` to `15`, same titles (11, 12 and 15 `@Ignore`) |
| `Values` (6 tests) | `ValuesTest`, same method names |
| `Entries.everyEntryNeedsARole` | `EntriesTest.everyEntryNeedsARole` |
| `LayoutProjection.projectsWritableSectionsAndCarriesTheRest` | `LayoutProjectionTest`, same name |
| `Feeds` (3 tests) | `FeedsTest`, same method names |
| `Portability.coreImportsOnlyFoundationAndNamesNoManufacturer` | `PortabilityTest.coreImportsOnlyStdlibAndCoroutinesAndNamesNoManufacturer` |
| `Portability.portableStateHoldsNoNativeFrameOrObject` | Not ported: the Kotlin import rule (only `kotlin.*`, `kotlinx.coroutines.flow.*` and `java.util.UUID`) keeps platform types out |
| `GroupTargets.strictAndEligibleSubsetFromAdmission` | `GroupTargetsTest`, same name |

Parameterized Swift scenarios run each fixture family inside one JUnit test.

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
