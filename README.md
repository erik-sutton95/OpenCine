# OpenCine

The shared platform of the OpenCapture camera apps (OpenPocketCine, OpenInstaCine, OpenZCine):
camera contracts, media math and runtime, the UI 2.0 design system, the multicam engine and the
DJI, Nikon and Insta360 integrations, for iOS (Swift package) and Android (one Gradle build),
plus the atlas that maps the portfolio. One repository, one version.

Status: candidate. Automated checks pass; nothing here is hardware-qualified on its own (apps
qualify behavior on physical cameras). Not yet published.

## What lives here

| Path | What |
|---|---|
| `Package.swift`, `Sources/`, `Tests/` | One Swift package, `OpenCine`: every product below plus the developer-only harness targets |
| `Fixtures/` | Data shared by Swift and Kotlin tests (`live-video-nal-vectors.tsv`, `camfov-vectors.tsv`, `saved-cameras/`) |
| `Android/` | One Gradle build: modules `core`, `media`, `platform`, `decoder`, `vulkan`, `monitor-ui`, `appkit`, `multicam`, `dji`, `nikon`, `insta360-shell`, `insta360-luna` |
| `scripts/` | `android-vulkan-sync-test.sh` (Vulkan present regression, host CPU), `vendor-lucide-icons.py` |
| `docs/<area>/` | Per-area guides moved from the former repositories: [core](docs/core/README.md), [ui](docs/ui/README.md), [appkit](docs/appkit/README.md), [multicam](docs/multicam/README.md), [dji](docs/dji/README.md), [nikon](docs/nikon/README.md), [insta360](docs/insta360/README.md), [harness](docs/harness/README.md) |
| `atlas/` | OpenCapture atlas: repository registry, routing docs, compatibility records, publish tooling, navigation evals ([atlas/README.md](atlas/README.md)) |

## Products

Swift products keep the module names the apps already import. Android modules keep their
coordinates `com.opencapture.opencine:<module>`.

| Area | Swift products | Android modules | Depends on |
|---|---|---|---|
| Core | `OpenCineCore` | `core` | nothing (Foundation; Kotlin stdlib, coroutines) |
| Core | `OpenCineMedia` | `media` | `OpenCineCore` / `core` |
| Core | | [`platform`](docs/platform/README.md) (Android Keystore and configured credential storage) | Android framework only |
| Core | | `decoder` (MediaCodec live-view decoder) | `media` |
| Core | `OpenCineFrameIO` (optional) | | nothing |
| Core | `OpenCineMotion` (optional) | | `OpenCineCore` |
| Core | `OpenCineRelay` (optional) | | nothing |
| Core | `OpenCineRelayApple` (optional; the relay's Bonjour, socket and encoder shell) | | `OpenCineRelay` |
| Core | `OpenCineWatch` (optional; the watch companion: phone WatchConnectivity relay, wrist monitor) | | `OpenCineRelay`, on iOS `OpenCineApple` |
| Core | `OpenCineApple` | `vulkan` (native renderer) | `OpenCineCore`, `OpenCineMedia` |
| Core | `OpenCineCoreTestSupport` (tests only) | `core` test fixtures | `OpenCineCore` |
| Android JNI | `OpenCineJNISupport` (JNI copy helpers for Swift Android libraries; re-exports C target `OpenCineJNI`) | | `OpenCineJNI` |
| UI | `MonitorPresentation`, `MonitorUI` | `monitor-ui` | nothing |
| App shell | `OpenCineAppKit` (saved cameras, connection model, cameras and pair screens, root and monitor lifetime, common controls) | `appkit` | `OpenCineCore` / `core` |
| App shell | `OpenCineAppUITesting` (UI tests only: the XCUITest cases every app runs by subclassing) | | nothing (XCTest) |
| Multicam | `OpenCineMulticam` | `multicam` | `OpenCineCore` / `core` |
| DJI | `OpenCineDJI`, `OpenCineDJIAndroid` (Swift side of `DjiNative`, + C target `OpenCineJNI`) | `dji` (JNI facade `DjiNative`) | `OpenCineCore`, `OpenCineMedia` / `core`, `media`, `decoder`, `platform` |
| Nikon | `OpenCineNikon`, `OpenCineNikonAndroid` (Swift side of `NikonNative`: Android session layer and JNI exports) | `nikon` (JNI facade `NikonNative`) | `OpenCineCore`, `OpenCineJNISupport` / `core` |
| Insta360 | `Insta360Protocol`, `Insta360Apple` (+ C target `CKcp`), `Insta360AppleTestSupport` (tests only) | `insta360-shell`, `insta360-luna` | `OpenCineCore` / `core` |
| Harness | none (targets `HarnessEngine`, `HarnessComposition`, `HarnessTests`; SIMULATED, never ships) | | everything above except UI |

The package has no third-party dependencies, so linking one product resolves nothing else.

## Which app uses what

| App | Swift products | Android modules |
|---|---|---|
| OpenPocketCine | `MonitorUI`, `MonitorPresentation`, `OpenCineCore`, `OpenCineMedia`, `OpenCineMotion`, `OpenCineRelay`, `OpenCineRelayApple`, `OpenCineFrameIO`, `OpenCineApple`, `OpenCineMulticam`, `OpenCineDJI`, `OpenCineDJIAndroid` (Android .so) | `core`, `media`, `platform`, `decoder`, `vulkan`, `monitor-ui`, `multicam`, `dji` |
| OpenInstaCine | `MonitorUI`, `MonitorPresentation`, `OpenCineCore`, `OpenCineMedia`, `OpenCineMotion`, `OpenCineRelay`, `OpenCineRelayApple`, `OpenCineApple`, `Insta360Protocol`, `Insta360Apple` (+ `Insta360AppleTestSupport` in tests) | `core`, `media`, `platform`, `decoder`, `vulkan`, `monitor-ui`, `insta360-shell`, `insta360-luna` |
| OpenZCine (`opencine/integration`) | `MonitorUI`, `MonitorPresentation`, `OpenCineCore`, `OpenCineMedia`, `OpenCineFrameIO`, `OpenCineApple`, `OpenCineMulticam`, `OpenCineNikon`, `OpenCineNikonAndroid` and `OpenCineJNISupport` (Android .so) | `core`, `monitor-ui`, `multicam`, `nikon` |
| OpenZCine engine-port candidate | `MonitorUI`, `MonitorPresentation` | `monitor-ui` |

Each app pins one commit of this repository in its `opencine-pins.txt` (`OpenCine <sha>`);
`scripts/checkout-opencine.sh` in the app checks it out next to the app in CI.

## Work on every app from here

Open this repository in your editor or agent and work on all three apps from it: the atlas
clones missing app checkouts next to it (`python3 atlas/tools/atlas.py ensure`), lists the open
issues of every repository (`issues`), shows which apps use a symbol or file and where
(`impact <symbol or path>`) and turns an issue into a task folder with one worktree per repository
(`task start <repo>#<n>`). The workflow and rules are in [AGENTS.md](AGENTS.md); agent skills for
issues, triage and propagating a shared change are in `.claude/skills/`.

## Develop locally with an app

Check this repository out next to the app (`~/Work/OpenCine` beside `~/Work/OpenPocketCine`).
The app's candidate branch already points here:

- Swift: the app's root `Package.swift` has `.package(path: "../OpenCine")` and
  `ios/project.yml` (or the Runner project) has one local package `../../OpenCine`; both name the
  same directory, so Xcode sees one package.
- Android: the app's `settings.gradle.kts` includes this build once, by name:

  ```kotlin
  includeBuild("../../../OpenCine/Android") {
      name = "opencine"
      dependencySubstitution {
          substitute(module("com.opencapture.opencine:core")).using(project(":core"))
          // ...one line per module the app uses
      }
  }
  ```

Edit here, then run the app's own checks against the change. Local paths bypass versions, so a
release is validated again without them ([atlas/docs/PUBLISH.md](atlas/docs/PUBLISH.md)).

## Test the apps on devices

[docs/testing/TESTER-GUIDE.md](docs/testing/TESTER-GUIDE.md) builds each app against
`integration/thin-app`, installs it on an iPhone and an Android phone and gives the device
checklist per app. Which app code moved to which OpenCine owner, with commits and line counts:
[docs/testing/RETIRED-OWNERS.md](docs/testing/RETIRED-OWNERS.md).

## Build and test

```sh
swift build && swift test                     # macOS host: every Swift test target
xcodebuild -scheme MonitorUI -destination 'generic/platform=iOS Simulator' build
xcodebuild -scheme OpenCineApple -destination 'generic/platform=iOS Simulator' build
xcodebuild -scheme Insta360Apple -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
cd Android && ./gradlew test lint assembleRelease   # JDK 17+, Android SDK (ANDROID_HOME or local.properties)
scripts/android-vulkan-sync-test.sh           # NDK Vulkan headers needed
python3 -m unittest discover -s atlas/tests && python3 atlas/tools/atlas.py check
```

CI runs the same set ([.github/workflows/ci.yml](.github/workflows/ci.yml)), plus a strict
concurrency build of the Core and Multicam areas with warnings as errors.

## Versioning and releases

- One version for everything: every Swift product and Android module ships together under one
  semantic version and one tag (`0.1.0` first). Artifacts record the source SHA.
- During `0.x` an incompatible interface change bumps the minor version (`0.1` to `0.2`);
  compatible fixes are patch releases. Apps pin an exact version and commit their lock files.
- A shared change lands here first; each app moves its pin in its own reviewed update and is
  verified there (operator-visible UI on a physical device) before it ships.
- Native/JNI schema, relay wire and app versions are tracked separately from this version.
- Publishing (one repository, one tag, app pins) is scripted and rehearsed in
  `atlas/tools/publish.py`; steps and pending decisions are in
  [atlas/docs/PUBLISH.md](atlas/docs/PUBLISH.md).

## License

Apache License 2.0 ([LICENSE](LICENSE), [NOTICE](NOTICE)). Bundled third-party resources
(Sora, Lucide, Tabler-derived glyphs, KCP, Luna protocol reference):
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). DJI, Nikon, Insta360 and Luna are
trademarks of their owners, used for identification only; this project is not affiliated with
or endorsed by them.
