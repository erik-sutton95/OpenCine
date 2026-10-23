# Tester guide: thin-app integration

How to build OpenPocketCine, OpenInstaCine and OpenZCine against OpenCine on
`integration/thin-app`, install them on your own iPhone and Android phone, and check each app
on a real camera. Which app code moved where: [RETIRED-OWNERS.md](RETIRED-OWNERS.md); what the
apps still keep and why: [COMPATIBILITY-INVENTORY.md](COMPATIBILITY-INVENTORY.md).

Status at the 2026-10-10 checkpoint: locally committed candidate. All three apps and
generated apps use the same capability-driven live and settings composition on each platform.
Pocket remains the common UI reference. Safe areas, camera pages, popups, capture headers,
circular focus reset and View Assist labels have shared owners; integration slots carry actual
hardware controls. Expanded View Assist uses short single-line captions and the
square cells used by compact favorites. Settings, inspectors and accessibility
retain full tool names.
Common false color offers CineStop, Video, IRE and Limits with LOG/709 reads. Shared scope,
peaking and two-axis mirror behavior retain native ownership and deployed preference keys.

The earlier exact twenty-gate matrix `275f8e15` retains its recorded source scope. The final
label delta passed eleven scoped gates (`e5f18775`): 3,156 Swift Testing cases in 375 suites and
177 XCTest cases, strict concurrency, 2,259 Android cases with zero failures and two known Core
skips, both iOS simulator architectures, three signed iOS builds for testing and all three full
Android consumers. Current app Android XML totals are Pocket 234, Insta 207 and Nikon 902,
with zero failures, errors or skips. Consumer staging, lint, debug/release and instrumentation
compilation passed; Nikon also passed its Wear/native packaging checks. Nine strict signatures,
six iPad profiles and four Pocket/Insta APK/JNI bindings passed. Compilation is not device proof.
The separate opt-in cleanup driver `9a909df` passed its Nikon signed build and source review;
its hardware restoration has not passed. It changes no shipping source or native admission rule.

Recorded Pocket/Luna original full camera workflows passed (`1946de9e` / `801a7c65`) at their
bound products. Luna's exact new clip belongs to SD bank 3 and is absent from internal bank 2
(`2787fbe1`); transfer and capture destination are not inferred. Pocket's receive/decoder fault
scenarios passed within their injected scope; the initiating Sentry dropout cause remains unknown.
Eleven optional generation-owned ingress diagnostics are implemented for future diagnosis.

Nikon's whole camera workflow remains failed/incomplete. Current native connection, complete
projected catalogue, ISO change/restoration and narrow layout observations retain their scope.
Initial label products passed native iPad portrait/landscape expand/collapse checks. The current
options run reached all eight false-color/read combinations, four mirror combinations and both
landscapes but failed final restoration, so the testcase is RED. Captured local mirror settings
still require restoration; later attempts stopped before preference changes because the camera
was not found. iPad automation worked without pending approval at the last readiness observation.
Background recovery, confirmed recording, exact new-clip playback/reopen and saved relaunch still
need a closed current Nikon proof. Android hardware, Dynamic Island phone edges, real two/four
camera operation, device performance and unexecuted special states remain untested.

Source ownership and official current duplication are bound by `b9c99891`, its legacy-glass
follow-up `b218c210`, and committed measurement `1819853f`. SDK/app matches include preserved
test oracles and bounded native/compatibility adapters; decreased totals do not mean zero copies.
The coding ledger counts adopted owners with scoped automated checks; physical qualification,
canonical integration and publication are separate. Pins, remotes and publication are unchanged.
Pocket/Insta exploratory UI-test edits remain preserved and excluded from commits. Existing
reference/accessibility/decoder skips and Nikon formatting/privacy-fixture failures retain their
recorded exclusions. Historical tables and every original checklist below retain their scope and
acceptance criteria.

What counts as a regression:

- **OpenPocketCine and OpenInstaCine** must behave exactly like their `main` build: same
  features, controls, flows and layout. Any difference not in the app's "Differences from
  `main`" table is a regression. The rows in those tables are known and scheduled to be
  restored to `main`; report a row only once its status says restored.
- **OpenZCine** adopts the newer shared look and flows of Pocket and Insta. The changes listed
  under [OpenZCine](#6-openzcine) are intended. A Nikon camera feature that worked on its `main`
  and is missing or broken is a regression.
- Items in [Already wrong on `main`](#7-already-wrong-on-main) are not regressions. Items in
  [Fixed during the migration](#8-fixed-during-the-migration) were regressions: re-check them.

Contents: [Revisions](#revisions-under-test) ·
[Set up](#1-set-up) · [Build and install](#2-build-and-install) ·
[Common checks](#3-common-checks-every-app) · [OpenPocketCine](#4-openpocketcine) ·
[OpenInstaCine](#5-openinstacine) · [OpenZCine](#6-openzcine) ·
[Already wrong on `main`](#7-already-wrong-on-main) ·
[Fixed during the migration](#8-fixed-during-the-migration) ·
[What is verified](#9-what-is-verified-and-what-is-not) · [Report](#10-report-a-regression) ·
[Refresh](#11-refresh-this-guide)

## Revisions under test

The current locally committed product revisions are:

| Repository | Product revision |
|---|---|
| OpenCine | `9a909dfca79bceb7cfe113ca0990d98f3e99467d` |
| OpenPocketCine | `3c753de685202ffd4ce2a23e4b30c21b79989652` |
| OpenInstaCine | `d1b8b8a527b6ced92d46f42fbcc51ba77b26f00d` |
| OpenZCine | `4460a435f190bcc67eb73bd945340e86eac78b9a` |

A later docs-only SDK commit changes these three tester documents only. Current build receipts
bind source bytes rather than the older HEAD of the frozen actual build copies. The working
sources of all owned committed files match these product revisions; unrelated exploratory UI
tests are disclosed separately. No source or consumer result is relabeled as a physical pass.

### Historical revision setup, 2026-10-08

| Repository | Working HEAD, before uncommitted changes | Parity baseline (`main`) | Pinned OpenCine (`opencine-pins.txt`) |
|---|---|---|---|
| OpenCine | `7a0d073150c181cad702ca1b3b749e6bb5ed37bd` | `d739bbdb` | |
| OpenPocketCine | `55465f8a9b3a68a7663eb35fbb44869cfd4c5694` | `27b15028` | `5d7c9ecd` |
| OpenInstaCine | `e5e6e5e5897b7254459d2aa666d4ca0b2071dbb7` | `35b6f33b` | `400962e1` |
| OpenZCine | `61fc7109f9a3fc699d5f97f0f174bef17de1b55a` | `9ac41387` (origin/main) | `400962e1` |

The earlier automated checks used frozen actual consumer worktrees and source manifests under
the coordinator's `CODEX-RESUME-20261007` evidence packet. These historical HEADs alone do not
reproduce those working inputs. Current product linkage is listed above. Nikon's parity baseline is the
recorded `origin/main` revision above; the older local `main` lacks Android upright-picture
fix #382. Record all four final commits and installed build identities in every device report.

The app pins are older than the shared code the apps now use and were not moved (a pin move
needs the maintainer's approval). Always build against a sibling OpenCine checkout at
`integration/thin-app`; `scripts/checkout-opencine.sh` then only warns
`../OpenCine is at ..., pinned ...`, which is expected.

Production counts and their exclusions are recorded in
[RETIRED-OWNERS.md](RETIRED-OWNERS.md#current-production-counts-2026-10-10).
Its dated working-tree census includes nonignored new sources and excludes deleted files.
The October 10 census `5e3f1569` is bound to these current sources. Line reduction alone
does not qualify behavior or prove that an interface became simpler.

## 1. Set up

### Tools (once)

| Tool | Version | Used for |
|---|---|---|
| Xcode | 26 (26.2 used by the automated checks) | iOS and watchOS builds |
| `xcodegen`, `just` | Homebrew | iOS project generation, app recipes |
| JDK | 17 or newer, in `JAVA_HOME` | Android Gradle |
| Android SDK | platform `android-37.0`, NDK `28.2.13676358`, CMake `3.22.1` | APK, Vulkan renderer |
| Swift toolchain | swift.org 6.3.3 in `~/Library/Developer/Toolchains/` (or set `SWIFT_EXECUTABLE`) | Swift core in the Android APK |
| Swift Android SDK | `swift-6.3.3-RELEASE_android`, then its `scripts/setup-android-sdk.sh` with `ANDROID_NDK_HOME` at NDK 27 | same |

Install the Swift Android SDK with the URL and checksum from OpenPocketCine's or OpenInstaCine's
`scripts/ci-install-swift-android.sh` (OpenZCine has no copy):

```sh
~/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift sdk install \
  "<SDK_URL>" --checksum "<SDK_CHECKSUM>"
```

Set `ANDROID_HOME` (for example `~/Library/Android/sdk`); the shared Android build has no
`local.properties`.

### Check out the four repositories side by side

The apps find OpenCine only by relative path (`../OpenCine` in `Package.swift`,
`../../OpenCine` in `ios/project.yml` or Nikon's `ios/Runner.xcodeproj`,
`../../../OpenCine/Android` in `Apps/Android/settings.gradle.kts`), so the four folders must be
siblings. From existing clones
in `~/Work`:

```sh
T=~/Work/thin-app-test
mkdir -p "$T"
for r in OpenCine OpenPocketCine OpenInstaCine OpenZCine; do
  git -C ~/Work/$r worktree add --detach "$T/$r" integration/thin-app
  git -C "$T/$r" log -1 --format="$r %h %s"
done
```

`--detach` is needed because `integration/thin-app` is already checked out in another
worktree. Remove the folder afterwards with `git -C ~/Work/<repo> worktree remove "$T/<repo>"`.

To compare with `main` (and for checks C1 and C21), build the app's `main` the same way from a
second folder. `main` does not use OpenCine, so it needs no sibling:

```sh
git -C ~/Work/<App> worktree add --detach ~/Work/main-test/<App> origin/main
```

## 2. Build and install

The shared modules added since the last revision of this guide (Swift
`OpenCineCameraVocabulary`, `OpenCineAppKitApple`, `OpenCineCameraControls`; Android
`camera-vocabulary`, `camera-controls`) come in through the sibling OpenCine checkout: nothing
to install or configure. If you built an earlier snapshot (for example `test/device-1`) in the
same Xcode, run Product > Clean Build Folder first: stale OpenCine modules in DerivedData make
shared types ambiguous and the build fails.

### iOS (all three apps)

1. Pocket and Insta: `cd "$T/<App>/ios" && xcodegen generate` (or `just ios-generate` from
   the app root). Their Xcode project is generated and git-ignored: make every change in
   `ios/project.yml`, never in the generated project. Nikon: open the checked-in
   `ios/Runner.xcodeproj` (no generation step).
2. For your own team, change `DEVELOPMENT_TEAM` (every target) and the app and watch bundle IDs
   (Pocket and Insta in `ios/project.yml`, then regenerate; Nikon in Xcode's Signing &
   Capabilities, do not commit it). In the watch `Info.plist` set
   `WKCompanionAppBundleIdentifier` to your app's bundle ID.
3. Select the app scheme and your iPhone, Run. The App ID needs the **Hotspot Configuration**
   and **Access Wi-Fi Information** capabilities (camera Wi-Fi join; Nikon also associated
   domains). A free personal team may not grant Hotspot Configuration (unverified); use a paid
   team.
4. Optional: Frame.io needs a `Frameio.local.xcconfig` with an Adobe client ID and redirect
   next to the app's `Frameio.xcconfig` (`ios/OpenPocketCine/`, `ios/OpenInstaCine/`,
   `ios/Runner/`; copy `Frameio.local.xcconfig.example`). Local
   builds have no crash-report DSN: use Report a problem or Share Diagnostics instead.

Keep the same team and bundle ID as your `main` build to test the upgrade path (C1, C21).

| App | Folder | App scheme | Watch | Bundle ID on `main` |
|---|---|---|---|---|
| OpenPocketCine | `OpenPocketCine/ios` | `OpenPocketCine` | `OpenPocketCineWatch` | `com.opencapture.openpocketcine` |
| OpenInstaCine | `OpenInstaCine/ios` | `OpenInstaCine` | `OpenInstaCineWatch` | `com.opencapture.openinstacine` |
| OpenZCine | `OpenZCine/ios` (`Runner.xcodeproj`) | `Runner` | `OpenZCineWatch` | `com.opencapture.openzcine` |

SIMULATED scenarios are developer-only. The dedicated opt-in physical qualification test also
uses the Pocket/Insta `UIReview` schemes, with normal app launch and no simulated camera
arguments; Nikon uses `RunnerPhysicalQualification`. Scheme names alone do not establish
whether a run used a real camera. Bluetooth, Local Network and hotspot joins do not work in
the Simulator.

### Opt-in camera-network automation (iOS hardware pass)

`PhysicalCameraNetworkTests` (every app) and `PhysicalCameraPairingTests` (OpenZCine only)
drive the Z3 network and first-pair checks on a real iPhone through the production UI, the
system alerts and the Settings app (the only way to change a permission on hardware). They
live in `Sources/OpenCineAppUITesting` and each app's UI test bundle subclasses them in one
line. They skip unless the test runner sees `OPV_PHYSICAL_NETWORK_PROBE=1`, and they skip on
a simulator, so hosted CI and ordinary local test runs never execute them. They issue no
camera setting, record or media command; a case that turns the Local Network switch off turns
it back in its teardown.

Device and camera: an unlocked iPhone signed for UI testing (paid team, see step 3 above),
with Wi-Fi on and the camera saved in the app once (one normal pairing). OpenZCine runs against
a Nikon Z body, OpenPocketCine against the Pocket 3, OpenInstaCine against the Luna. Schemes:
`RunnerPhysicalQualification` (OpenZCine, `ios/Runner.xcodeproj`), `OpenPocketCineUIReview`
and `OpenInstaCineUIReview` (after `xcodegen generate`). xcodebuild hands an environment
variable to the test runner when it carries the `TEST_RUNNER_` prefix:

```sh
cd "$T/OpenZCine/ios"
TEST_RUNNER_OPV_PHYSICAL_NETWORK_PROBE=1 \
TEST_RUNNER_OPV_PHYSICAL_CAMERA_NAME="<saved camera name, as its row reads>" \
TEST_RUNNER_OPV_PHYSICAL_CAMERA_SSID="<the camera's Wi-Fi name>" \
xcodebuild test -project Runner.xcodeproj -scheme RunnerPhysicalQualification \
  -destination "platform=iOS,id=<iPhone UDID>" -resultBundlePath "$OUT/z-network.xcresult" \
  -only-testing:RunnerUITests/PhysicalCameraNetworkTests/testCancelSystemJoinThenRetry
```

Run one case per invocation with `-only-testing` (Pocket: `OpenPocketCineUITests/...`, Insta:
`OpenInstaCineUITests/...`). Every case attaches screenshots, the system alerts it met and its
timings to the result bundle (`camera-network.*`). In the table, `CAMERA_NAME` and `CAMERA_SSID`
are `OPV_PHYSICAL_CAMERA_NAME` and `OPV_PHYSICAL_CAMERA_SSID`; every input takes the
`TEST_RUNNER_` prefix on the command line.

| Case | Z3 item | Inputs and operator step |
|---|---|---|
| `PhysicalCameraNetworkTests/testLocalNetworkDeniedThenAllowedOnSavedCamera` | 6, 7a | `CAMERA_NAME`; optional `OPV_PHYSICAL_DENIAL_MAX_SECONDS` (default 60) |
| `PhysicalCameraNetworkTests/testLocalNetworkAllowedBeforeDeadlineConnects` | 7b | `CAMERA_NAME` |
| `PhysicalCameraNetworkTests/testJoinAnsweredLateConnectsWithoutSecondPrompt` | 7c | `CAMERA_NAME`, `CAMERA_SSID` (the case forgets that Wi-Fi first) |
| `PhysicalCameraNetworkTests/testCameraOffFailsTypedThenRecovers` | 7d | `CAMERA_NAME`; switch the camera off before the run and back on once the app shows its failure (the case waits 10 minutes); optional `OPV_PHYSICAL_MISSING_MAX_SECONDS` |
| `PhysicalCameraNetworkTests/testCancelSystemJoinThenRetry` | 8 | `CAMERA_NAME`, `CAMERA_SSID` (the case forgets that Wi-Fi first) |
| `PhysicalCameraPairingTests/testFirstRunPairsNearbyCameraOnSharedPage` | first run | OpenZCine, fresh install; camera in "connect to smart device" mode on the same Wi-Fi |
| `PhysicalCameraPairingTests/testWiFiPairingAsksLocalNetworkOnceAfterTransportChoice` | 1 | OpenZCine, fresh install as above |
| `PhysicalCameraPairingTests/testUSBPairingAsksNoLocalNetwork` | 2 | OpenZCine, fresh install, camera on USB-C |
| `PhysicalCameraPairingTests/testHDMIMonitoringAsksNoLocalNetwork` | 2 | OpenZCine on an iPad with a capture device; skips without one |
| `PhysicalCameraPairingTests/testCameraAccessPointManualPairingWithCameraOff` | 3 | OpenZCine, fresh install; `OPV_PHYSICAL_AP_SSID`, `OPV_PHYSICAL_AP_KEY` from the camera's screen |
| `PhysicalCameraPairingTests/testLocalNetworkDeniedThenAllowedOnPermissionsStep` | 5 | OpenZCine, fresh install |

A fresh install means deleting the app from the iPhone before the case (that resets its privacy
answers); the case then counts the Local Network and camera prompts exactly. On an install that
already answered them, `TEST_RUNNER_OPV_PHYSICAL_STRICT_PROMPTS=0` records the counts without
asserting them. If a fresh OpenZCine install opens the shared "Find your camera" page instead
of the wizard, run `testFirstRunPairsNearbyCameraOnSharedPage` first (it saves the camera) and
the wizard cases after it with strict prompts off. `OPV_PHYSICAL_PAIR_SECONDS` (default 240) bounds a pairing that waits on the
camera. A case that could not reach its precondition (iOS joined the camera Wi-Fi without
asking, no capture device) ends as skipped with the reason, never as passed.

### Android (all three apps)

Every app is one Gradle project in `Apps/Android`, arm64-v8a only, Android 10 (API 29) or
newer. The build cross-compiles the app's Swift core first (`stageSwiftCore`, wired to
`preBuild`), so the Swift toolchain and Swift Android SDK above are required.

```sh
cd "$T/<App>/Apps/Android"
./gradlew :app:assembleDebug
adb -s <serial> install -r app/build/outputs/apk/debug/app-debug.apk
```

Pocket and Insta debug builds install as `<applicationId>.debug` with a "Dev" launcher name,
next to a store build. Nikon's debug build keeps `com.opencapture.openzcine`: uninstall a Play
or otherwise signed copy first. To test the upgrade path, install a `main` debug build first,
then the integration debug build over it (same signing key: build both on the same machine).

| App | Modules | `applicationId` | Notes |
|---|---|---|---|
| OpenPocketCine | `:app` | `com.opencapture.openpocketcine` | `just android-build`, `just android-install [serial]`; build type `perf` is for profiling only |
| OpenInstaCine | `:app`, `:monitor` | `com.opencapture.openinstacine` | `just android-build`; no install recipe, use the `adb install` above |
| OpenZCine | `:app`, `:core-api`, `:wear`, `:wear-relay` | `com.opencapture.openzcine` (phone and Wear) | `just android-install [serial]`; a sideload release needs your own `ANDROID_KEYSTORE_*` and `ANDROID_KEY_*` variables (`docs/android-distribution.md`); Frame.io needs `Apps/Android/frameio.local.properties`; Wear OS: `./gradlew :wear:assembleDebug`, install `wear/build/outputs/apk/debug/wear-debug.apk` on the watch |

Debug-only screens (preview, backdrop, shell review, local replay "NOT A LIVE CAMERA", the
Nikon demo session) are SIMULATED developer tools, not features to test.

## 3. Common checks (every app)

Run these in each app on iOS and on Android, with the app's own camera, then the app's section
below. "Changed" names the shared owner that replaced the app's own code; a failure there points
to that row of [RETIRED-OWNERS.md](RETIRED-OWNERS.md). PD-n and ID-n are rows of the Pocket and
Insta [differences tables](#differences-from-main-openpocketcine).

| # | Check | Steps | Expected | Changed |
|---|---|---|---|---|
| C1 | Upgrade keeps your data | Install `main`, pair a camera, rename it, star a clip, change a few assists and settings. Install the integration build over it. | Same cameras, names, saved Wi-Fi, favorites and preferences; no new pairing or camera approval | Saved cameras and settings stores (`OpenCineAppKit`) |
| C2 | Permissions | Deny Bluetooth or Local Network (iOS), Nearby devices (Android 12+) or Location (Android 10-11), then pair. | Error names the fix, in `main`'s words. iOS: Open Settings where only Settings fixes it (a denied permission), Try again when Bluetooth is off (ID-10). Android: the pair page's primary action asks for the permission or turns Bluetooth on | Cameras and pair pages (`OpenCineAppKit`); Android permission gate (`appkit`) |
| C3 | First pair | Cameras → pair a new camera → Continue → approve on the camera → accept the Wi-Fi join. Also Pair on a nearby card. | The four pair pages as on `main` (find, approve, join camera Wi-Fi, open the video link); Pair on a nearby card starts at once; live picture once; the card keeps its name after relaunch (PD-1, ID-5, ID-6) | Pair page, connection flow, integration session |
| C4 | Reconnect | Relaunch, Connect on the saved card. Cancel once during scan, approval or join. | No password or approval prompt; Cancel stops the attempt cleanly | Same |
| C5 | Forget | Forget a saved camera, then pair it again. | Card gone; on iOS its saved Wi-Fi too. Android also drops the Wi-Fi (kept fix: PD-3, ID-12) | Saved cameras store |
| C6 | Link loss and recovery | Toggle phone Wi-Fi briefly; background and foreground; open Media or Settings and come back. | Last picture stays, live returns without re-pairing, no black or frozen picture, no stuck "Waiting for live view" | Native live video runtime and recovery (`OpenCineApple`, `native-runtime`, `vulkan`) |
| C7 | Live HUD | Battery, storage, format, timecode, REC row; DISP clean view; Fit/Fill where offered; Lock; portrait and landscape; iPad window resize (iOS). | Same readouts as `main`, nothing clipped or missing; Lock blocks every control | `AppShell`, `MonitorScreen` (`OpenCineAppKit`, `MonitorUI`); Android live chrome buttons (`camera-controls`) |
| C8 | Camera controls | Change ISO, shutter (and angle), white balance, EV, format/fps and mode. | Lands on what the camera reports within about 3 s, as on `main`: Pocket says the camera's own message for a refused write, Insta "ISO was not applied by the camera."; a write the camera does not take reverts silently (PD-4, ID-1) | Common control seam (`OpenCineCore`), the integration; Android capture sheets (`camera-controls`) |
| C9 | Record | Record and stop with the on-screen button, with and without Record Confirmation where offered; hardware or gamepad trigger where the app supports it. | Camera starts or stops exactly once; the lamp follows the camera; right after connecting, record waits for the camera's first record state (kept fix: PD-7) | Same |
| C10 | Exposure assists | Peaking, zebra, false color (each mode), EV meter, traffic lights, ND suggestions; open the palette in landscape. | Overlays line up with the picture; same result as `main` on the same scene; the open palette covers the values bar | Assist state, sampling and views (`OpenCineApple`, `OpenCineMedia`, `MonitorUI`) |
| C11 | Scopes | Waveform, parade, histogram, vectorscope; drag and resize each. | Same traces as `main`; moving a scope never blacks out or reconnects the feed | Scope plots and sampling (`MonitorUI`, `OpenCineMedia`) |
| C12 | Looks and framing | LUT Auto (also on a downloaded log clip in playback), a creative LUT and a custom `.cube`; guides, grid, crosshair, de-squeeze, mirror, level. | Same picture as `main`; custom LUT survives relaunch | Media math (`OpenCineMedia`), clip color profile reader (Android `media`), monitor UI |
| C13 | Settings | Open every Settings tab; change one value per tab, relaunch; use Reset where offered. | Same tabs and rows as the app's `main` (Nikon: the shared layout); values persist. Kept fixes: Insta Android App Information, screen-reader names, colour dots | Settings page (`MonitorUI`), operator settings owners |
| C14 | Media browser | Open Media; switch storage, filter and sort, star, delete, cache a clip, then browse offline. | Same clips as the camera; delete removes the file on the camera; cached clips play without the camera | Library, cache and selection (`OpenCineAppKit`), catalog (`MonitorUI`), media producer (integration) |
| C15 | Playback | Play, pause, scrub, loop; assists and LUT during playback; rotate; return to live. | Picture (not black), audio where the clip has it, live resumes after leaving | Playback model and page (`MonitorUI`), native playback owners |
| C16 | Share and export | Share an original; Save to Photos. Export with the LUT baked in (iOS; Nikon also Android). | Saved file plays in Photos; baked export shows the look | Delivery panel and coordinator (`OpenCineAppKit`), exporter (`OpenCineApple`) |
| C17 | Frame.io (iOS; Nikon also Android) | With Frame.io keys configured: sign in, upload one clip, cancel a second. | Upload completes; cancel stops the second (Pocket wording: PD-11); a sign-in from `main` survives the upgrade | `OpenCineFrameIO`, delivery coordinator |
| C18 | Diagnostics | Report a problem; Share Diagnostics. | Report sheet opens with the attachment | App-owned (unchanged) plus shared incident export |
| C19 | Watch | Apple Watch (iOS; Nikon also Wear OS, needs Play services): open the watch app while connected; record from it. | Preview, timecode, storage, battery; record acts on the camera shown, never another one (PD-8) | `OpenCineRelay`, session-targeted commands |
| C20 | Camera pickers (Pocket, Insta) | On each body open every capture list: ISO (and ISO limit), shutter, WB, EV, color mode, resolution/fps/format, focus, shooting mode, gimbal mode and speed, joystick curve, gamepad stick. | Same entries and order as `main`. Pocket never offers I-Log, Dolby Vision, ISO 160 or the Luna sizes (8K, 6K, 4K 9:16, 3K, 8K 2.35:1, 4K 2.35:1). Insta: Standard, I-Log, Dolby Vision; ISO steps the same with and without 160 in the camera's list | Camera vocabulary (`OpenCineCameraVocabulary`, `camera-vocabulary`), capture sheets (`camera-controls`) |
| C21 | Upgrade keeps saved looks and media | On `main`: pick a LUT (Pocket: an official DJI LUT, then a custom `.cube`; Insta: Auto on I-Log; Nikon: a RED LUT and a custom LUT), a color mode, cache two clips and star one; Nikon also zebra, crush/clip, de-squeeze and Feed Upscaler. Upgrade. | Same LUT, color mode and assist values selected; cached clips play offline without a new download; Nikon de-squeeze shows the same picture (see [OpenZCine](#6-openzcine)) | Stored raw values in the vocabulary, `StoredCustomLUT` and `CustomLUTIndex` (`OpenCineMedia`), `MonitorUpscaler`, media cache keys |
| C22 | Head tracking (Pocket, Insta iOS) | AirPods: allow motion, Calibrate, turn your head, STOP; then close the panel and background the app while tracking. | Gimbal follows your head as on `main`; the permission note names the app; tracking stops on STOP, panel close and background | `HeadphoneMotionBridge` (`OpenCineAppKitApple`) |
| C23 | Watcher sheet and saved watcher secrets (Pocket, Insta iOS; Nikon iOS passcodes) | Share this feed with a passcode; open the Wi-Fi join-code sheet; watch from a second iPhone. Repeat after relaunch and after the upgrade from `main`. Nikon: set a broadcast passcode and join a passcode broadcast on `main`, upgrade, broadcast and rejoin. | Sheet shows the network and join code, closes when the network or live state changes; the host passcode, the watcher identity and the passcodes a watcher remembered on `main` still work (no retyping). Nikon: the same broadcast passcode is enforced and the remembered code joins without retyping; both now live in the Keychain | `WatcherWiFiCodeView` (`OpenCineAppKitApple`), `WatcherRelayKeychain` (`OpenCineRelayApple`), Keychain service unchanged |

Moved into shared code since the last revision of this guide, and the checks that cover it:

| Area | Apps, platforms | Re-check |
|---|---|---|
| Camera vocabulary: control values, picker lists, status, models, media listing values, LUT choice, recovery copy | Pocket, Insta, both | C20, C21, C14, C6 |
| Capture sheets, zoom chip, pinch and dial, lock, focus reset, AE unlock, gimbal stick and chrome, game controller driver | Pocket, Insta Android | C7, C8, P3, P4, I5, I7 |
| Pairing permissions and system bars | Pocket, Insta Android | C2 |
| Exposure meter reading, gamepad shutter-angle HUD, playback video layout, scope exposure ceiling | Pocket, Insta iOS | C10, C11, C15, P4 |
| Clip color profile reader (QuickTime keys) | Pocket, Insta Android | C12 |
| Head tracking; watcher join-code sheet and relay Keychain | Pocket, Insta iOS | C22, C23, P8, I9 |
| Media browser on the shared catalog; Link Health scale; Feed Upscaler and custom LUT index | Nikon iOS | N11, C13, N5, C21 |
| Phone battery readout | Nikon Android | C7 |
| Multicam stage (finished) | Pocket, Nikon | P7, N14 |
| Playback, audio/scopes, settings, media and delivery owner consolidation | Pocket, Insta, both; Nikon typed native adapters | C10-C17; current complete consumer/device gates still required |

## 4. OpenPocketCine

Cameras: Osmo Pocket 4 Pro (main test camera), Pocket 4, Pocket 3, Nano (no gimbal, zoom or
tap focus), Action 6 (built from a capture, never checked on a real camera). iOS 17+ (iPhone and
iPad), Android 10+.

| # | Check | Platforms | Steps | Expected | Changed |
|---|---|---|---|---|---|
| P1 | Per-body layout | both | Connect each body you have. | Tiles match `main` | Layout from DJI capabilities (`OpenCineDJI`) |
| P2 | Wi-Fi and Hotspot setups | both | Add setup → Wi-Fi or Hotspot, connect; force a failure. | One Add setup, offered only while a setup kind is missing; 4-step progress (up to about 1 min); failure offers Edit setup, Try again, Camera Wi-Fi | `OpenCineDJIApple`, `dji` connection bootstrap |
| P3 | Focus, zoom, tracking | both | Tap to focus, long-press AE-L, tap a face, double-tap for object tracking; zoom chip, pinch, disc; FOCUS tile; APERTURE on Action 6. Zoom while recording in D-Log2. | Same as `main`; zoom limited per FORMAT; in D-Log2 zoom stays locked while recording, with the note | Apple camera control owners (`OpenCineDJIApple`), Android `camera-controls` |
| P4 | Gimbal | both | Joystick (size, invert, dead zone); Mode, Speed, Ramp; double-tap Recenter or Level; Motion Control A/B/C with Loop; game controller. Open the Motion editor and tap outside it; relaunch with a paused move. | Same motion as `main`; gimbal stops when you let go; the editor takes its touches; a paused move survives launch | Gimbal control owner (`OpenCineDJIApple`), `OpenCineMotion`, `camera-controls` |
| P5 | Audio meters | both | AUDIO on a body with a mic. | AUDIO is offered; levels move with sound, same ballistics as `main` | `MonitorUI` audio meter |
| P6 | HDR display, Photo mode | both | HDR display on; switch to Photo, press the shutter. | Record button acts as shutter; photo lands on the camera | Common control seam |
| P7 | Multiview | both | Grid icon → network → 2, 3 and 4 cameras; Record all; per-tile record; Camera settings panel (change ISO, shutter, WB, focus per camera); Grid and Center stage. | Each tile shows its own result; the settings drums work per camera (PD-10 for record) | `OpenCineMulticam`, shared stage (`OpenCineAppKit`, `appkit`) |
| P8 | Share this feed / Watch a feed | iOS | Host with a passcode (QR); a second iPhone watches and requests control. | Watcher sees the feed and assists; control requests reach the host camera | `OpenCineRelay` (wire bytes unchanged), C23 owners |
| P9 | Media extras | iOS | Bake LUT (+ exposure), Convert log, Frame.io. Android shares originals only. | Same as `main` | `OpenCineApple` exporter |

The app's own detailed list: the "Physical device checklist" in OpenPocketCine
`docs/OPENCINE-INTEGRATION.md`.

### Differences from `main` (OpenPocketCine)

Recorded in the app's own doc, OpenPocketCine `docs/OPENCINE-INTEGRATION.md`, "What changes for
users" (line numbers at `f64d26a8`). Pocket must match `main` 1:1. The parity lane (2026-10-06)
checked each row against `main` (27b15028): restored to main; kept fix, your call (`main`'s
behavior was a defect, see [Kept fixes](#kept-fixes-your-call)); or already matched main.

| Row | Difference | Recorded in | Status |
|---|---|---|---|
| PD-1 | Cameras and pairing on the shared flow: Continue on a nearby camera; the saved card shows its own attempt and typed failure actions (Open Settings) | lines 58-62 | restored to main (also: Pair on a nearby card starts at once, nearby cards say "Needs approval on the camera", the Wi-Fi caption is the phase label, no Rename setup on setup chips, the iPhone hotspot ask names the camera) |
| PD-2 | A malformed saved-camera record no longer wipes the readable ones | lines 65-66 | kept fix, your call |
| PD-3 | Android Forget also drops the camera's saved Wi-Fi (iOS did on `main`) | lines 66-67 | kept fix, your call |
| PD-4 | iOS HUD shows a pending ISO or WB value until the camera reports it | lines 71-73 | restored to main (iPhone strip: ISO and shutter keep the camera's value until it answers; a custom white balance shows the request at once) |
| PD-5 | Nano shows no live timecode (it never reports one) | lines 74-77 | restored to main (single view shows the timecode on every body, Nano included; Multi View hides it on a Nano, as on `main`) |
| PD-6 | Android: APERTURE sheet and drum only on Action 6; FOCUS from the body's declaration | lines 77-79 | already matched main (`main` also showed APERTURE only on Action 6 and FOCUS only on Pocket 3, 4 and 4 Pro) |
| PD-7 | Record sends start or stop for the reported state; right after connecting it says "Waiting for the camera's record state" | lines 80-81 | kept fix, your call (`main` also sent start or stop, never a toggle, but assumed "not recording" before the first report) |
| PD-8 | After a link change the watch says "Camera changed. Try again." instead of acting | lines 82-83 | kept fix, your call |
| PD-9 | Android scopes, zebra and false color use the clip ceiling of the feed they show (Multiview tile, playback) | lines 84-85 | kept fix, your call |
| PD-10 | Multiview: start or stop per camera after a re-check, per-tile results, Photo mode disables Record all and its tile record, the confirmation closes on a replaced link (Android as iPhone) | lines 86-91 | start or stop per camera, re-check and per-tile results: already matched main. Photo mode and the Android confirmation closing on a mode change: kept fix, your call |
| PD-11 | Frame.io (iPhone): ids with `/ ? # \`, spaces or control characters refused; a refresh without a refresh token keeps the old one; a cancelled batch says "Cancelled." | lines 92-95 | ids and refresh token: kept fix, your call. A cancelled batch: already matched main (no failed count on either) |

Test-fixture-only differences (simulator `UIReview` builds, never on a device): the review
starts from the first-run palette order, its player controls work without the private test
clip, and its saved-hotspot prompt runs through the review's own DJI port. The review camera never
reports a record state, so its record button reads "Recording state unknown" (PD-7). The review
Nano is a Nano body, so it shows no FOCUS tile, as a Nano on `main` (`main`'s review Nano kept
the Pocket body's FOCUS tile).

Also restored (not a listed row): Android Settings View Assist and Display show `main`'s rows
(the union had shown the newer shared sections), and the tab strip keeps `main`'s spacing.
Android Settings with no camera connected offers the AUDIO clean-view pin, as on `main`. iPhone
Settings: Display shows `main`'s rows (caption, Edit view, one switch per item, then the pins),
the tab strip keeps `main`'s spacing, Sharing's "Show Wi-Fi code" link is blue again (the union
drew it white), and landscape View Assist keeps the tools in one column with EV Meter and LUT
beside them. ISO, shutter and white balance set from a picker sheet answer as `main` did, on
both platforms: the camera's own message on a refusal, nothing on a timeout (the iPhone union
said "The camera did not confirm ISO 800."). "Connect the camera to use its controls." and a
write held back after the camera state changed keep the shared copy (Android had dropped even
those).

## 5. OpenInstaCine

Camera: Insta360 Luna Ultra (firmware 1.1.15), 720p HEVC live feed at 25 fps. Force-quit the
Insta360 app on every nearby phone before pairing. No Multiview (as on `main`).

| # | Check | Platforms | Steps | Expected | Changed |
|---|---|---|---|---|---|
| I1 | Saved approval | both | Relaunch and reconnect; then delete and reinstall the app. | No camera prompt on reconnect; after reinstall the camera asks again (new identity) | Luna session (`Insta360Apple`, `insta360-luna`); keychain service unchanged |
| I2 | Reconnect timings | both | Wi-Fi off mid-live, back on; Bluetooth off. | "Reconnecting", then "Connection keeps dropping" at about 45 s with Retry. Android: live again in about 30 s with no tap; Bluetooth off keeps live over saved Wi-Fi (about 8 s) | Same |
| I3 | Modes and capture | both | Record in Video, Timelapse, TimeShift, Slow Motion, PureVideo; take a Photo. | Lamp waits for the camera, timer runs, stop saves a file | Common control seam (`OpenCineCore`) |
| I4 | Camera settings | both | ISO Auto/100-6400 (incl. 160); shutter 1/8000-1/5 and angle; WB Auto/2000-10000 K (applies 3.5-5 s later, dial holds); EV in thirds; FORMAT drum; Standard, I-Log, Dolby Vision; METER Matrix/Face. | Values and lists match `main` and what the camera reports | Same, camera vocabulary |
| I5 | Focus, zoom, Deep Track | both | FOCUS AF-S, AF-C, Product Showcase; tap focus; long-press locks the box; zoom 1/2/3/6/15x and pinch; Deep Track by double-tap, drag or face. | Search box turns green on lock; zoom to 15x on iPhone, the Android chip stops at 12x, as on `main` (ID-2) | Zoom and focus with common receipts, `camera-controls` |
| I6 | I-Log look | both | LUT → Auto on I-Log. iOS: flat I-Log preview preference. | Official I-Log to Rec.709 look ("Auto · I-Log → Rec.709" on Android) | `OpenCineMedia` (golden I-Log anchors) |
| I7 | Gimbal | both | Stick and game controller; Roll Lock, Roll & Tilt, FPV, FPV-V; speed; Recenter; Flip; Double-tap Level; Motion Control A/B/C; open the Motion editor and tap outside it. iOS: AirPods head tracking (C22). | Level within 0.4° in about 2 s; Motion Control counts down, loops, pauses, stops; the editor takes its touches | `OpenCineMotion`, shared motion settings, `camera-controls` |
| I8 | `.lrv` media | both | Album thumbnails (proxies hidden), download an original, play a `.lrv` with scopes and LUT, delete. | Delete also removes the `.lrv`; cached clips play offline | Luna media producer, shared library and playback |
| I9 | Watcher relay | iOS | Settings → Sharing hosts with a passcode; a second iPhone uses Watch a feed and requests record, focus or exposure. | Host grants; Android Sharing tab says "Coming soon" | `OpenCineRelay`, C23 owners |

Not on Luna at all, as on `main`: live audio, aperture, AE/AWB lock (ignore the opposite line in
the app's checklist). The app's own detailed list: the "Physical device checklist" in
OpenInstaCine `docs/implementation/opencine-integration.md`.

### Differences from `main` (OpenInstaCine)

Recorded in the app's own doc, OpenInstaCine `docs/implementation/opencine-integration.md`,
"What changes for users" (line numbers at `fc5e13b6`). Insta must match `main` 1:1. The parity
lane (2026-10-06) checked each row against `main` (35b6f33b): restored to main; kept fix, your
call (see [Kept fixes](#kept-fixes-your-call)); or already matched main.

| Row | Difference | Recorded in | Status |
|---|---|---|---|
| ID-1 | A write shows confirmed only after the camera reports it; a refused, unapplied or timed-out write says so | lines 162-164 | restored to main (a refused or unsent write says "ISO was not applied by the camera."; one the camera does not take reverts silently; iPhone counts only those toward Link Health again) |
| ID-2 | Zoom readout reaches 15x (`main` clamped readouts to 12x) | lines 165-166 | already matched main (iPhone `main` set the ceiling to 15x; the Android chip stopped at 12x then and now) |
| ID-3 | Clean view settings offer no AUDIO pin | lines 173-174 | Android: already matched main (Android `main` hid it too: no audio on a Luna). iPhone: restored to main (portrait and landscape Display offer the AUDIO pin) |
| ID-4 | iPhone Settings with no camera connected shows no gimbal, joystick, head-tracking, zoom chip or timecode rows | lines 174-177 | restored to main (iPhone; Android already matched: Timecode listed, gimbal and zoom need a camera) |
| ID-5 | Pair page rail "Find your camera" then four connect steps (`main`: four Luna pages); one instruction card per prompt, no Luna body text, check list or VPN banner during an attempt | lines 186-189 | restored to main |
| ID-6 | Pair on a nearby card opens the pair page with it selected (Continue starts it) | lines 189-190 | restored to main |
| ID-7 | Nearby card reads "Ready to pair", "Luna Ultra · nearby" (iOS; `main` "Insta360 · nearby"), "Insta360 Luna Ultra · nearby" (Android; `main` "Pocket · ...") | lines 190-192 | restored to main ("Insta360 · nearby", "Needs approval on the camera"); Android uses iPhone `main`'s words instead of its "Pocket · ...": kept fix, your call |
| ID-8 | Android offline card says "Not found. Power it on to reconnect" | lines 192-193 | kept fix, your call (no em dash: iPhone `main`'s "Not found. Power it on to reconnect"; Android `main` used an em dash) |
| ID-9 | Connecting card caption is the prompt ("Tap Join when iOS asks...") instead of the phase | lines 193-194 | restored to main |
| ID-10 | iOS offers Open Settings when Bluetooth is off or not allowed | line 195 | restored to main (Bluetooth off or not ready: `main`'s words with Try again; not allowed: Open Settings) |
| ID-11 | One undecodable saved record no longer empties the list on the next save | lines 195-196 | kept fix, your call |
| ID-12 | Android Forget also drops the camera's saved Wi-Fi (iOS did on `main`) | lines 196-197 | kept fix, your call |
| ID-13 | iOS "on the camera network" tests the Luna's 192.168.42.x (`main` tested Pocket's 192.168.2.x, never true) | lines 197-198 | kept fix, your call |

Accepted, stays (coordinator decision): a saved camera that still carries a hotspot setup
connects from that chip over the camera's own Wi-Fi, without `main`'s "Turn on Personal
Hotspot" prompt. On `main` no Insta camera could add a hotspot setup and Luna joined its own
Wi-Fi anyway; only simulator review data reached the prompt.

Also restored (not a listed row): Android Settings View Assist and Display show `main`'s rows
(the union had shown the newer shared sections). iPhone Settings: Display shows `main`'s rows
(caption, Edit view, one switch per item, then the pins), Sharing's "Show Wi-Fi code" link is
yellow again (the union drew it white), and landscape View Assist keeps the tools in one column
with EV Meter and LUT beside them.

Test-fixture-only differences (simulator `UIReview` builds, never on a device): the review's
connecting card shows the Luna step "Joining camera Wi-Fi" (`main`'s review went through the
DJI adapter: "Moving the camera to Studio-5G"), the review camera gets a zoom range so the zoom
chip shows, the review starts from the first-run palette order and its player controls work
without the private test clip.

### Kept fixes (your call)

Where `main`'s behavior was a defect (data loss, security or privacy, a wrong-camera or blind
action, or a check that could never work), the parity lane kept the fix instead of restoring
`main`. Each is your call: say which to restore and it goes back.

| Row | What `main` did | Why it is a defect | What you see now |
|---|---|---|---|
| PD-2, ID-11 | iOS decoded the saved list in one piece; one bad record returned an empty list and the next save overwrote every camera | Data loss | Unreadable records are kept; the readable ones load |
| PD-3, ID-12 | Android Forget removed the card but left the camera's Wi-Fi name and password stored | Privacy | Forget also drops the stored Wi-Fi (as iOS always did) |
| PD-7 | Record sent start or stop, but before the camera's first report it assumed "not recording", so a camera already recording got Start | Blind action | Right after connecting, record waits for the camera's first record state ("Waiting for the camera's record state") |
| PD-8 | Watch and watcher-relay commands carried no camera id and ran on whichever camera was live | Wrong camera | After a link change the watch says "Camera changed. Try again." |
| PD-9 | Android kept one clip ceiling for every feed: after an ISO 1600 clip, live ISO 800 clipping (231-247) went unflagged in false colour, the legend and the waveform until the next scope tap; Multiview tiles overwrote each other | Measurement correctness (coordinator) | Each feed (live, Multiview tile, playback) has its own ceiling |
| PD-10 | A camera in Photo mode got the video record frame from Record all or its tile; on Android the confirmation stayed open across a mode change | Blind action, stale plan (coordinator) | Photo mode disables Record all and that tile's record; the Android confirmation closes on a mode or capability change, as on iPhone |
| PD-11 | Frame.io ids from the server went into authenticated request paths unchecked; a refresh without a refresh token stored none, so every later request failed until Disconnect and Connect | Security, token handling | Bad ids are refused before any request; the previous refresh token is kept |
| ID-7 (Android) | The nearby card said "Pocket · Luna Ultra · nearby" (the DJI fork's family name on a Luna) | Wrong camera named (coordinator) | iPhone `main`'s "Insta360 · nearby" with "Needs approval on the camera" |
| ID-8 | The Android offline card read "Not found" + em dash + "power it on to reconnect" | Copy rule: no em dash in UI copy | iPhone `main`'s "Not found. Power it on to reconnect" |
| ID-13 | iOS "on the camera network" tested Pocket's 192.168.2.x, never true on a Luna, so "Leave camera Wi-Fi?" never appeared before Frame.io and uploads ran on the camera Wi-Fi | A check that could never work | The check tests the Luna's 192.168.42.x |
| Insta App Information (Android) | System > App Information showed the DJI fork's "DJI Black" theme and "DUML / BLE + Wi-Fi" protocol, with DJI help text | Wrong camera named (coordinator) | iPhone `main`'s "Charcoal" and "Insta360 / BLE + Wi-Fi" with their help |
| Colour dots (zebra and peaking options) | A dot drew the app accent under another colour's name: Pocket iPhone "Cyan" and peaking "Blue" (the accent blue); Android, both apps, "Amber", "Cyan" and peaking "Blue" (Pocket blue, Insta yellow). Insta iPhone already drew each dot's paint | Wrong colour named (coordinator) | Each dot shows the colour its overlay paints |
| Timecode screen-reader name (iPhone, both apps) | With no timecode yet VoiceOver read the placeholder: "Timecode --:--:--", spoken as dashes | Accessibility (coordinator) | "Timecode not available"; with a timecode it reads "Timecode 01:02:03" as on `main` |
| Screen-reader names and touch targets (Android, both apps) | Clean view pins, System buttons and the zebra threshold sliders had no spoken name; the System buttons' touch area was the capsule itself | Accessibility (coordinator) | Each has a name (for example "Keep LUT in clean view", "Highlight threshold"); the System buttons take touches across 48 dp around the unchanged capsule (it sits 1 px lower) |

Deliberate copy difference in both apps: every `main` string with an em dash (Pocket pair page
body, hint and instruction lines; the offline card; the Android Clean view caption in Settings) uses the period or comma OpenInstaCine
iPhone `main` used for the same line.

## 6. OpenZCine

Cameras: Nikon ZR, Z9 and Z5II work on `main`; Z6, Z6II, Z6III, Zf, Z8, Z7 and Z7II were
never tested there. Transports: camera access point Wi-Fi (OCR scan of SSID and key, or manual),
router, phone hotspot, USB-C; HDMI capture (UVC) as a picture source on iPad and Android. iOS
17+, Android 10+ (arm64).

New for Nikon testers: the cameras page, pair page, live chrome, Operator Setup, media catalog,
playback, delivery popup and Multicam come from the shared UI; Nikon keeps its gold accent and
its own controls in the shared screen's typed slots (capture, tools, panels). Read the
intended changes below before you report a difference.

| # | Check | Platforms | Steps | Expected | Changed |
|---|---|---|---|---|---|
| N1 | Every transport | both | Pair over camera Wi-Fi (scan and manual), router, hotspot and USB-C. iOS: the AccessorySetupKit Wi-Fi join. | PIN confirms on the camera; a saved setup appears; live view starts | Shared cameras and pair pages over `NikonIntegration`, `NikonDiscovery`; transports in `OpenCineNikon` |
| N2 | Passive discovery | both | Keep the cameras page open for 2 minutes while another phone has a live session on the same body. | The other session survives; while browsing the app never opens the PTP/IP control port or sends a PTP byte (only mDNS and the app's relay presence port 15741) | `NikonDiscovery` (`OpenCineNikon`, `nikon`) |
| N3 | Reconnect | both | Pull USB-C or power-cycle the body during live view; a failed first connect. | Last frame stays, marked as held, during a bounded reconnect; then Retry connection or Operator menu; first-connect failure offers Try again | Typed Nikon reconnect decision; shared frame runtime holds the frame |
| N4 | HDMI capture | iPad, Android | Plug a UVC capture device, then unplug it. | HDMI picture shows; unplug recovers cleanly | `OpenCineApple` UVC source (iOS) |
| N5 | DISP and framing | both | DISP 1, 2 (clean, per-tool pins), 3 (command dashboard, timecode keeps running); per-element display switches; shared FPS/link telemetry in landscape; pinch zoom with tap focus following it; vertical camera with Auto-Rotate Feed. iOS: Feed Upscaler, Feed Noise Reduction. | Same tools as `main`, in the shared chrome; FPS/link values use the shared telemetry presentation in landscape | Shared `MonitorScreen` with Nikon slots (`NikonCommandControls`, `CommandGrid`); `MonitorUpscaler` |
| N6 | Focus dial (MF strip) | both | Turn the Focus dial on in the FOCUS popup; drive focus in video and photo; release; tap to focus; focus reset. | Focus moves by wire; release does not re-AF | `MFDriveVerticalScrub` / `MFDriveStrip` in the tools slot |
| N7 | e-VR | both | iOS: VR / e-VR panel. Android: DISP 3 tile. Try with a RAW codec. | Toggles on the body; disabled for RAW codecs | Nikon panels slot |
| N8 | Camera settings | both | ISO (Auto ISO, R3D NE Low/High base), shutter angle, iris, WB (presets, Kelvin, fine, tint), exposure mode, codec and 8/10-bit, resolution/fps, AF mode, area and subject, metering, audio, picture control. | Pickers mirror the body; values match the body; clock syncs on connect when drift is over 5 s | Common seam for ISO, WB and record; exposure descriptors for common controls |
| N9 | Photography mode | both | Shutter, hold for burst, bulb/time, timers, EV meter, instant playback, burst stacks; fire a shot on the body itself. | Same as `main`; body-fired shots appear; the media button shows the photo glyph | `NikonCaptureAction` in the system slot |
| N10 | Nikon assists | both | Audio meters, aspect markers, custom frames, split compare, RED LUTs and the in-app RED LUT download, de-squeeze 1.6x and custom 1.00-2.00x; each in live and playback. | Same as `main` apart from the assist changes below (Android peaking is grainier, as on `main`) | Shared assist state, palette, inspector and scope panels; shared native frame and effects runtime |
| N11 | Media | both | Both cards; Photos and Videos tabs; `.HIF`; RAW+JPEG pairs; set a rating; slow-motion conform preview in playback. iOS: pull to refresh, hold then drag to select, Cache, Favorite, Share and Delete from the tray; card capacity cards; burst stacks; the photo viewer's pinch zoom. | Ratings land on the card; pairs stay together; burst count, RAW+J, EXPORTED and CACHING captions as on `main` | Nikon catalog producer, shared library and conform math; iOS shared `MonitorMediaCatalog` |
| N12 | Delivery | both | LUT-baked Share; Frame.io; internet hop while on the camera's Wi-Fi. Android: export a clip with timecode. | Upload completes and returns to the camera network; the exported timecode track runs the whole clip | Shared exporter (Android owner emulator-verified only), `OpenCineFrameIO` |
| N13 | Share This Feed and remotes | both | Broadcast with a passcode, watch from a second phone, hand control over; record from Apple Watch, Wear OS, a Bluetooth shutter and a relay viewer holding control. | Each remote records the camera it shows; refusals put the button back | Relay record targets, watcher authority |
| N14 | Multicam (new, not on `main`) | both | Multicam with 2 to 4 bodies over router, hotspot or USB; group record; member control; try a camera Wi-Fi setup, HDMI, the same body twice and a fifth body. | Group records; the refused cases are refused with a reason | `OpenCineMulticam`, `NikonMulticamPolicy`, budget of 4, shared stage |

The app's detailed list: the "Physical device checklist" (items 1 to 29, Multiview, performance
baselines, Z-1a) and "What changes for users" in OpenZCine `docs/OPENCINE-INTEGRATION.md`.

### Intended changes from `main` (OpenZCine, do not report)

Screens and flows:

- Cameras page, pair page, live chrome, Operator Setup, media, playback, delivery popup and
  Multicam are the shared screens. Multi-Z Multicam is new (`main`: one camera per session).
- Cameras page: one card per body with a chip per setup; connect progress and failures show on
  the card (no full-screen connect card); no camera border color or icon; one setup can no
  longer be renamed (names are kept); a nicknamed body is titled with its nickname (was
  "ZR_6002199 · A-cam"). A reachable setup still wins over a newer offline one, as on `main`,
  except a Wi-Fi setup found only by name after a DHCP move: the card then uses the most
  recent setup.
- iOS: one cover at a time (Settings opened over Media replaces it); a camera connect closes a
  standalone Media or Settings, also Settings re-opened by a Frame.io or RED hop; standalone
  Media and Settings are overlay pages without the slide-up animation.
- Android: after the app is killed in the background, a watcher-only phone starts on the pair
  page again; a connect shows the monitor one frame later (no stale cover frame).
- iOS look: solid page surfaces instead of Liquid Glass, corner radius 12 (was 16), the shared
  background instead of the warm gradient, pressed controls follow Reduce Motion.

Live view and assists:

- The palette orders tools by use (photo mode starts with PLAY, then EV). Gone: the Settings >
  Display toolbar order list, its eye switches and the Exposure/Framing bar switches. A long
  press opens the shared inspector with tabs (iOS: instead of the anchored popup). Playback uses
  the same palette (no separate sliders button) and offers no PLAY or EV.
- A fresh install takes the shared defaults: zebra 99 IRE (was 100), crush/clip zero (was
  quarter), rule of thirds on; card resets use them too. Values saved on `main` are kept; a
  saved toolbar order is ignored.
- Choosing a guide ratio or a false color scale turns that assist on. The camera EV meter
  cannot be pinned for DISP 2. The portrait "three scopes" refusal toast is gone (portrait
  still shows the two newest). CineStop false color uses Nikon's stops ramp.
- De-squeeze: a saved "Horizontal" (it narrowed the picture) becomes the shared Vertical, so
  the picture stays the same; Horizontal now letterboxes.
- Scope panels: drag directly (no hold first); iOS resizes from the corner; a still hold opens
  the tool's options; a panel never moved starts at the screen center and may sit over the AF
  box (`main` parked it beside the feed or top-left); positions are kept per orientation and
  shared by live and playback. Android TalkBack's "Recenter" action on scopes is gone (the
  false color key keeps its own).
- iOS meters: the audio meter takes the Pocket look (no AUDIO or SENS captions; the mic
  sensitivity is in the VoiceOver value; a source with no report draws at the floor); the false
  color key takes the shared look (grey track, header like "ZC Stops · L3G10") and starts at
  the center instead of bottom-left.
- iOS Link Health uses the shared scale (Sora type, shared orange).

Media (iOS):

- Shared catalog: header "N items · category" and a LIBRARY status box, category counts, pull
  to refresh instead of the REFRESH pill, the sort chip names the order, fixed column counts,
  shared source tags (ON CAMERA, ON PHONE, CACHING) and favorite label ("Add favorite").
- Selection: hold, then drag; the shared tray (All, Clear, Share, Cache, Favorite, Delete)
  replaces the top Close/Delete/Share bar; the share popup sits above the tray.

Settings, diagnostics and commands:

- iOS Sharing tab: switches instead of Off/On choices, sentence-case labels, a masked passcode
  field (still digits only, 4 at most), no Wi-Fi code row; Watching, Control Requested and
  Camera Control sit in a "Watchers" card while broadcasting.
- iOS Storage > Frame.io: "Not configured" (was "Not set up in this build"); on the camera's
  Wi-Fi "Sign in" (was "Sign in over internet") opens the same hop confirmation; a sign-in error
  shows under the card.
- Diagnostics use the shared redacted report: renamed sections, "Journal (last N lines)",
  home paths, emails, MAC addresses, passphrases and network names redacted.
- Record Confirmation records the target you confirmed (`main` recomputed the toggle). With
  control handed to another device, record presses from the watch or a Bluetooth shutter are
  refused (`main` allowed them). The iOS FPS readout no longer jumps back on a repeated frame
  time.

## 7. Already wrong on `main`

Not regressions: each behaves the same on the app's `main`. The ones marked follow-up are
decisions for you (section 9).

| Item | Apps, platforms | Note |
|---|---|---|
| Landscape assist palette, expanded: the plate is 107 of 110 dp/pt, so its bottom row (LUT, Camera settings) is 3 short (45 dp) | Pocket, Insta, both | follow-up |
| Settings action pills are under the 48 dp touch minimum | Pocket Android (Insta: 48 dp) | follow-up |
| Playback "Back to media" is 48 pt and the portrait PEAK tool 48 pt tall (the UI tests expect 54 and 50) | Pocket, Insta iOS (iPhone 16 Pro, iOS 26.2) | likely device-dependent test values |
| Scope panels have no TalkBack or VoiceOver move, resize or recenter action | Pocket, Insta (Nikon too, see its changes) | follow-up |
| Sharing a cached clip the FileProvider cannot serve falls back to the public gallery | Pocket, Insta Android | security follow-up; callers pass only cached clips |
| AUDIO never appears on a Luna (it declares no audio), nor in the Insta simulator review, so two Insta AUDIO UI tests fail as on `main` | Insta | Pocket offers AUDIO on every body, as on `main` (P5) |
| Android peaking is grainier than iOS | Nikon | |
| The focus recenter button can sit under a scope panel placed on it | Nikon iOS | |

Test-only, no device impact: Pocket Motion `testZoomChipKeepsRecordingColorGateWithEditorOpen`
(the review fixture cannot raise the D-Log2 note; P3 checks it on hardware); Insta
`testActualOwnedVideoPlayback...` fails instead of skipping without the private clip; Insta
Android `MotionProgramSessionTest` depends on test order; OpenCine
`MonitorReaderWriterMediaExporterTests` and some Nikon Android instrumented tests are
sensitive to machine load.

Stale tests updated to `main`'s behavior (each failed on `main` the same way and passes there
after the update, as strict as before): Pocket iOS `testSettingsTabsShareEdgesAndKeepSelection`,
now `testSettingsTabsKeepBaselineSpacingAndSelection` (the tabs are 6 pt apart, as on `main`).

## 8. Fixed during the migration

Regressions the lanes found against `main` and fixed (automated tests pin each one). Re-check
them on hardware.

| Fixed | Apps, platforms | Re-check |
|---|---|---|
| The open Motion editor and run pill took no touches (outside tap hit Record, scroll and drag fell through) | Pocket, Insta iOS | P4, I7 |
| Launching the app cancelled a paused programmed move | Pocket iOS (Insta the same code) | P4 |
| Multiview camera settings drums (ISO, shutter, WB, focus) said "Setting not available" | Pocket, both | P7 |
| The expanded landscape palette drew under the camera values, and its lower chips could not be tapped | Pocket, Insta, Nikon iOS | C10 |
| VoiceOver reached hidden chrome (zoom chip under an open picker, Nikon system controls under a full-screen page) and missed the palette expand handle | Pocket, Insta, Nikon iOS | C7 with VoiceOver |
| Privacy and Terms links on the cameras page (`main`: only in Settings) | Pocket, Insta | C3 |
| Add setup offered while no setup kind was missing (two Add setup) | all three | P2, C3 |
| One media clip read by VoiceOver as two elements | Pocket, Insta iOS | C14 with VoiceOver |
| Settings action pills (for example Open Support) with a 31.6 dp touch target | Nikon, Insta Android | C13 |
| Film glyph instead of the photo glyph on the media button in photo mode | Nikon, both | N9 |
| FPS and link chip missing from the landscape status bar | Nikon, both | N5 |
| Black playback picture on the emulator, also on `main` (the player started before its picture surface existed) | Pocket, Insta Android | C15 |
| Exported movie's timecode track lasted 0.8 s instead of the clip, also on `main` | Nikon Android | N12 |

## 9. What is verified and what is not

Target platforms: iOS 17+ (iPhone, iPad, Apple Watch) and Android 10+ arm64 (phone; Nikon also
Wear OS). Current automated and physical scopes are recorded at the top of this guide.
Pocket/Luna recorded full flows passed; current Nikon and the broader platform checklist remain
incomplete. The following table retains the October 8 results without qualifying later products.

### Historical verification, 2026-10-08

| Area | Recorded checks and remaining qualification | Physical |
|---|---|---|
| OpenCine shared code | Final SDK Swift v2: 3,132 Swift Testing cases in 372 suites + 176 XCTest passed; final strict v2 passed. Both retained all 1,290 source guards after the current private immutable progress callback capture. Optimized shipping Release v3 passed for both simulator architectures; this is compile-only. Android v24: 2,221 cases, zero failures/errors, two known Core skips; test/lint/release passed, 343 raw XML files frozen. Vulkan sync passed. Final Atlas unit v1: 102 cases, zero failures/skips, log `6d015007`; plain check passed. Earlier unit v3 retains its historical skip. Registered-ref `check --sources` failed with 32 historical-ref errors; local candidate duplication passed separately. Latest shared iOS palette correction passed in Nikon native v15; final combined-source binding recorded in first-pass matrix `7004c896`, with finite later deltas explicit and final current-doc-head supplement coordinator-owned | untested for current combined operator flows |
| OpenPocketCine | Portable v3: 76 cases and strict passed. Native v4: 580 cases, 579 passed, one original no-tree accessibility skip, zero failures; arm64/x86_64 products. Android v6: 233 cases, 44 raw XML files, zero failures/errors/skips; test/lint/debug/release/instrumentation compilation and Swift staging passed. Repository v2 and APK/JNI linkage passed. Original installed Android native matrix: 21 passed; original iOS MultiviewUIFlowTests: five passed, zero failure/skip. Focused original AX v1/v2 each reached the original no-tree skip (0 passed/0 failed/1 skipped); its VoiceOver assertions remain untested; final source/install binding recorded in first-pass matrix `7004c896`, with finite later deltas explicit and final current-doc-head supplement coordinator-owned | untested for current combined candidate |
| OpenInstaCine | Portable v2: 60 cases and strict passed; repository v2 passed. Native v13: 403 cases, 402 passed, one original accessibility-service skip, zero failures; arm64/x86_64 products. Android v8: 207 cases, 40 raw XML files, zero failures/errors/skips; test/lint/debug/release/instrumentation compilation and Swift staging passed. Whole original decoded-movie v4, metadata v2 and pointer-cancel v1 passed on the emulator; current APK/JNI/assets linkage passed. Final source/install binding recorded in first-pass matrix `7004c896`, with finite later deltas explicit and final current-doc-head supplement coordinator-owned | untested for current combined candidate |
| OpenZCine | Portable v1: 404 tests in 23 suites and strict passed. Android v5: 897 cases, 114 raw XML files, zero failures/errors/skips; test/lint/debug/release/Wear/instrumentation compilation and Swift staging passed. Original real-accessibility-service six v2 passed 6/0/0. Full native v15: 390 cases, 388 passed, two known skips, zero failures; arm64/x86_64 products. Current APK/AAB/staging/DEX/JNI linkage v5 passed (`5a13191a`): 99 debug/81 release production native DEX methods, 18 unused Vulkan methods pruned by existing R8 rules, all 99 production native exports retained; final source/install binding recorded in first-pass matrix `7004c896`, with finite later deltas explicit and final current-doc-head supplement coordinator-owned | untested for current combined candidate |
| Live picture, Metal and Vulkan | Simulator Metal and emulator EGL only. Original Pocket GPU oracle passed one test with 27 pixel comparisons (nine plans by three odd sizes) | untested on real GPUs |
| Bluetooth, Wi-Fi join, hotspot, USB, PTP, UVC | Unit tests with fakes; not possible on simulators | untested |
| Multiview and Multicam with 2 to 4 cameras | Existing shared control/lease/admission scenarios are SIMULATED. Original Pocket installed Android 21-case matrix passed, including four synthetic native Surface pictures. Original iOS MultiviewUIFlowTests passed five/zero failure/skip with existing default3/explicit4/one-capability inputs | real peer performance and hardware untested |
| AirPods head tracking, Apple Watch, Wear OS | Unit tests and watch builds | untested |
| VoiceOver, TalkBack | Original Nikon native accessibility/action/pixel six passed with the real simulator accessibility service; full native v15 passed. Insta's full native receipt retains its original accessibility-service skip. Pocket focused AX v1/v2 both retain the original no-tree skip with the real service enabled; v2 includes the two-fragment scene registration/restoration setup correction. Pocket's original picker/zoom/cover VoiceOver assertions did not execute. TalkBack not run | untested on a device |

Each result qualifies its recorded input and platform scope. Later Swift delivery actor and
immutable progress corrections (`19c4` to `532b` to `50758`) are separately qualified by the
current SDK suite/strict and both full original template eleven-case suites; they do not restamp
older app guard maps as exact current reruns. Nikon's final MediaBrowser comment-only delta
preserves executable bytes. Matrix `7004c896` retains those source exceptions. Nikon's two native skips are the
absent reference-proxy sample and the simulator VideoToolbox refusal of a real ZR JPEG frame.
Insta's whole movie checks actual Media3/GLES decoding of the original cached moving MP4s with a
SIMULATED catalogue; its eventual B-pixel assertion does not inject transient old-A buffers.
The Pocket 2/4 matrix separates command/lease membership from picture rendering: its four
retained Surface hosts use synthetic pixels, and native metadata/prepare tests use SIMULATED
observations. No existing exact two-decoded-picture installed selector is claimed or newly
required. These results do not qualify camera decoding, real two/four-peer performance or hardware.

Physical readiness at that historical checkpoint: Xcode reported the paired iPhone locked again and the original
selected physical test awaits unlock. The earlier 10:09 CEST unlocked state is historical
readiness, not a passed test. Android remains detached; no current combined physical result
exists. The opt-in driver keeps its original connection, raw ISO/recording, native pixels,
playback/reopen/recovery/saved relaunch and restoration requirements. Earlier standby/navigation
results retain their original scope.

Decisions for you after the device run:

- Pocket and Insta differences from `main` (sections 4 and 5): a parity lane restores them;
  the Status column says when.
- Scope panels without a TalkBack or VoiceOver recenter action: adding one to the shared panel
  helps all three apps but changes Pocket and Insta from `main`.
- Pocket Android Settings action pills under 48 dp (kept as `main`).
- MediaShare gallery fallback (Pocket, Insta Android): option, limit it to image and video
  types.
- Landscape palette 3 dp short (Pocket, Insta): +3 dp is not 1:1 with `main`.
- Code the apps still keep, with what blocks each item:
  [compatibility inventory follow-ups](COMPATIBILITY-INVENTORY.md#follow-ups).

Known open items at the October 8 revision (current status is above):

- App pins are stale (see [Revisions](#revisions-under-test)); a CI checkout of an app at
  `integration/thin-app` would fetch the old pin and fail to compile.
- All three recorded native/Android consumer gates now pass at their own inputs with the
  known native skips above. Final combined-source qualification recorded in first-pass matrix `7004c896`, with finite later deltas explicit and final current-doc-head supplement coordinator-owned.
- Full generated template v3 passed all original eight contracts plus three installed cases
  on each platform, with zero failures/skips (combined receipt `b9843798`). Camera data is
  SIMULATED; native decoding and installed operator/lifetime/persistence/isolation checks passed.
  The original Pocket iOS AX case retains its known no-tree skip; its VoiceOver assertions and
  current physical-device qualification remain untested.
- Final local candidate commits/content manifests, source counts, normalized duplication exit
  and installed-build binding recorded in first-pass candidate `f6f1ed71` and matrix `7004c896`; final status-only documentation is rebound separately. The existing PD/ID parity rows
  retain their dated, scoped status; the common and camera checklists are unchanged.

## 10. Report a regression

For each failure, note:

- app, platform, phone model and OS version, camera model and firmware;
- the four revisions you built ([Revisions](#revisions-under-test)) and whether `main` of the
  same app on the same phone and camera behaves differently;
- the check number (C7, P3, ...) or difference row (PD-4, ...), the steps, what you saw, and a
  screen recording or screenshot; Share Diagnostics output for connection or picture problems.

An issue in shared behavior (any C check, or an owner named in "Changed") belongs in OpenCine;
an issue only in an app's own panel belongs in that app.

## 11. Refresh this guide

1. Bind all four final candidate commits and content manifests. Record the unchanged pins
   separately until an authorized pin move occurs. Refresh production counts using the
   documented exclusions in [RETIRED-OWNERS.md](RETIRED-OWNERS.md), and replace section 9
   pending entries only with their exact current-source results (finish.matrix).
2. Update the Status of the PD and ID rows as the parity lane restores or decides each one
   (its brief lists every row with the app doc lines); drop a row once restored and checked.
3. Record what insta-ios and insta-android moved last in the "Moved into shared code" table.
4. Refresh the source and caller inventory in [RETIRED-OWNERS.md](RETIRED-OWNERS.md) and
   [COMPATIBILITY-INVENTORY.md](COMPATIBILITY-INVENTORY.md). Keep historical snapshots dated.
5. Add checks for anything new the lanes ship.
