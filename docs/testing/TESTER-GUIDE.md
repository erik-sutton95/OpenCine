# Tester guide: thin-app integration

How to build OpenPocketCine, OpenInstaCine and OpenZCine against OpenCine on
`integration/thin-app`, install them on your own iPhone and Android phone, and check each app
on a real camera. Which app code moved where: [RETIRED-OWNERS.md](RETIRED-OWNERS.md).

Status: candidate. Every check below passed only on simulators, emulators or in unit tests.
**Nothing in this migration has run on a physical camera or phone**: the device run this guide
describes is the first one.

What counts as a regression:

- **OpenPocketCine and OpenInstaCine** must behave exactly like their `main` build: same
  features, controls, flows and layout. Any difference not listed under the app's "Intended
  differences" below is a regression.
- **OpenZCine** adopts the newer shared look and flows of Pocket and Insta (cameras page, pair
  page, monitor chrome, settings, media, playback, delivery). A screen that now looks like
  Pocket/Insta is intended. A Nikon camera feature that worked on its `main` and is missing or
  broken is a regression.

Contents: [Revisions](#revisions-under-test) ·
[Set up](#1-set-up) · [Build and install](#2-build-and-install) ·
[Common checks](#3-common-checks-every-app) · [OpenPocketCine](#4-openpocketcine) ·
[OpenInstaCine](#5-openinstacine) · [OpenZCine](#6-openzcine) ·
[What is verified](#7-what-is-verified-and-what-is-not) · [Report](#8-report-a-regression) ·
[Refresh](#9-refresh-this-guide)

## Revisions under test

| Repository | `integration/thin-app` | Parity baseline (`main`) | Pinned OpenCine (`opencine-pins.txt`) |
|---|---|---|---|
| OpenCine | `6133cf67` | `d739bbdb` | |
| OpenPocketCine | `ae864436` | `27b15028` | `5d7c9ecd` (56 commits behind) |
| OpenInstaCine | `67c42504` | `35b6f33b` | `400962e1` (130 commits behind) |
| OpenZCine | `227bd272` | `9ac41387` (origin/main) | `400962e1` (130 commits behind) |

Snapshot of 2026-10-05; the insta, insta-black, multicam and nikon-assists lanes still land
here. Write down the four `git log -1 --format=%h` values of what you actually built in every
report.

The app pins are older than the shared code the apps now use and were not moved (a pin move
needs the maintainer's approval). Always build against a sibling OpenCine checkout at
`integration/thin-app`; `scripts/checkout-opencine.sh` then only warns
`../OpenCine is at ..., pinned ...`, which is expected.

## 1. Set up

### Tools (once)

| Tool | Version | Used for |
|---|---|---|
| Xcode | 26 (26.2 used by the automated checks) | iOS and watchOS builds |
| `xcodegen`, `just` | Homebrew | iOS project generation, app recipes |
| JDK | 17 or newer | Android Gradle |
| Android SDK | platform `android-37.0`, NDK `28.2.13676358`, CMake `3.22.1` | APK, Vulkan renderer |
| Swift toolchain | swift.org 6.3.3 in `~/Library/Developer/Toolchains/` (or set `SWIFT_EXECUTABLE`) | Swift core in the Android APK |
| Swift Android SDK | `swift-6.3.3-RELEASE_android`, then its `scripts/setup-android-sdk.sh` with `ANDROID_NDK_HOME` at NDK 27 | same |

Install the Swift Android SDK with the URL and checksum from any app's
`scripts/ci-install-swift-android.sh`:

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

To compare with `main` (and for check C1), build the app's `main` the same way from a second
folder. `main` does not use OpenCine, so it needs no sibling:

```sh
git -C ~/Work/<App> worktree add --detach ~/Work/main-test/<App> origin/main
```

## 2. Build and install

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

Keep the same team and bundle ID as your `main` build to test the upgrade path (check C1).

| App | Folder | App scheme | Watch | Bundle ID on `main` |
|---|---|---|---|---|
| OpenPocketCine | `OpenPocketCine/ios` | `OpenPocketCine` | `OpenPocketCineWatch` | `com.opencapture.openpocketcine` |
| OpenInstaCine | `OpenInstaCine/ios` | `OpenInstaCine` | `OpenInstaCineWatch` | `com.opencapture.openinstacine` |
| OpenZCine | `OpenZCine/ios` (`Runner.xcodeproj`) | `Runner` | `OpenZCineWatch` | `com.opencapture.openzcine` |

Schemes ending in `UIReview` and anything labelled SIMULATED are developer-only and never talk
to a camera. Bluetooth, Local Network and hotspot joins do not work in the Simulator.

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

Debug-only screens (preview, backdrop, shell review, local replay "NOT A LIVE CAMERA") are
SIMULATED developer tools, not features to test.

## 3. Common checks (every app)

Run these in each app on iOS and on Android, with the app's own camera, then the app's section
below. "Changed" names the shared owner that replaced the app's own code; a failure there points
to that row of [RETIRED-OWNERS.md](RETIRED-OWNERS.md).

| # | Check | Steps | Expected | Changed |
|---|---|---|---|---|
| C1 | Upgrade keeps your data | Install `main`, pair a camera, rename it, star a clip, change a few assists and settings. Install the integration build over it. | Same cameras, names, saved Wi-Fi, favorites and preferences; no new pairing or camera approval | Saved cameras and settings stores (`OpenCineAppKit`) |
| C2 | Permissions | Deny Bluetooth or Local Network (iOS), Nearby devices (Android 12+) or Location (Android 10-11), then pair. | Error names the fix and offers Open Settings | Cameras and pair pages (`OpenCineAppKit`) |
| C3 | First pair | Cameras → pair a new camera → Continue → approve on the camera → accept the Wi-Fi join. | Live picture once; the card keeps its name after relaunch | Pair page, connection flow, integration session |
| C4 | Reconnect | Relaunch, Connect on the saved card. Cancel once during scan, approval or join. | No password or approval prompt; Cancel stops the attempt cleanly | Same |
| C5 | Forget | Forget a saved camera, then pair it again. | Card and its saved Wi-Fi are gone (Android now also drops the Wi-Fi, as iOS did) | Saved cameras store |
| C6 | Link loss and recovery | Toggle phone Wi-Fi briefly; background and foreground; open Media or Settings and come back. | Last picture stays, live returns without re-pairing, no black or frozen picture, no stuck "Waiting for live view" | Native live video runtime and recovery (`OpenCineApple`, `native-runtime`, `vulkan`) |
| C7 | Live HUD | Battery, storage, format, timecode, REC row; DISP clean view; Fit/Fill where offered; Lock; portrait and landscape; iPad window resize (iOS). | Same readouts as `main`, nothing clipped or missing; Lock blocks every control | `AppShell`, `MonitorScreen` (`OpenCineAppKit`, `MonitorUI`) |
| C8 | Camera controls | Change ISO, shutter (and angle), white balance, EV, format/fps and mode. | Value shows pending, then what the camera reports (within about 3 s); refused or unapplied writes say so | Common control seam (`OpenCineCore`) and the integration |
| C9 | Record | Record and stop with the on-screen button, with and without Record Confirmation where offered; hardware or gamepad trigger where the app supports it. | Camera starts or stops exactly once; the lamp follows the camera, never a blind toggle | Same |
| C10 | Exposure assists | Peaking, zebra, false color (each mode), EV meter, traffic lights, ND suggestions. | Overlays line up with the picture; same result as `main` on the same scene | Assist state, sampling and views (`OpenCineApple`, `OpenCineMedia`, `MonitorUI`) |
| C11 | Scopes | Waveform, parade, histogram, vectorscope; drag and resize each. | Same traces as `main`; moving a scope never blacks out or reconnects the feed | Scope plots and sampling (`MonitorUI`, `OpenCineMedia`) |
| C12 | Looks and framing | LUT Auto, a creative LUT and a custom `.cube`; guides, grid, crosshair, de-squeeze, mirror, level. | Same picture as `main`; custom LUT survives relaunch | Media math (`OpenCineMedia`), monitor UI |
| C13 | Settings | Open every Settings tab; change one value per tab, relaunch; use Reset where offered. | Same tabs and rows as the app's `main` (Nikon: the shared layout); values persist | Settings page (`MonitorUI`), operator settings owners |
| C14 | Media browser | Open Media; switch storage, filter and sort, star, delete, cache a clip, then browse offline. | Same clips as the camera; delete removes the file on the camera; cached clips play without the camera | Library, cache and selection (`OpenCineAppKit`), media producer (integration) |
| C15 | Playback | Play, pause, scrub, loop; assists and LUT during playback; rotate; return to live. | Picture (not black), audio where the clip has it, live resumes after leaving | Playback model and page (`MonitorUI`), native playback owners |
| C16 | Share and export | Share an original; Save to Photos. Export with the LUT baked in (iOS; Nikon also Android). | Saved file plays in Photos; baked export shows the look | Delivery panel and coordinator (`OpenCineAppKit`), exporter (`OpenCineApple`) |
| C17 | Frame.io (iOS; Nikon also Android) | With Frame.io keys configured: sign in, upload one clip, cancel a second. | Upload completes; cancel reports "Cancelled."; a sign-in from `main` survives the upgrade | `OpenCineFrameIO`, delivery coordinator |
| C18 | Diagnostics | Report a problem; Share Diagnostics. | Report sheet opens with the attachment | App-owned (unchanged) plus shared incident export |
| C19 | Watch | Apple Watch (iOS; Nikon also Wear OS, needs Play services): open the watch app while connected; record from it. | Preview, timecode, storage, battery; record acts on the camera shown, never another one (Pocket: "Camera changed. Try again." after a link change) | `OpenCineRelay`, session-targeted commands |

## 4. OpenPocketCine

Cameras: Osmo Pocket 4 Pro (main test camera), Pocket 4, Pocket 3, Nano (no gimbal, zoom or
tap focus), Action 6 (built from a capture, never checked on a real camera). iOS 17+ (iPhone and
iPad), Android 10+.

| # | Check | Platforms | Steps | Expected | Changed |
|---|---|---|---|---|---|
| P1 | Per-body layout | both | Connect each body you have. | Tiles match `main`, except the intended differences below | Layout from DJI capabilities (`OpenCineDJI`) |
| P2 | Wi-Fi and Hotspot setups | both | Add setup → Wi-Fi or Hotspot, connect; force a failure. | 4-step progress (up to about 1 min); failure offers Edit setup, Try again, Camera Wi-Fi | `OpenCineDJIApple`, `dji` connection bootstrap |
| P3 | Focus, zoom, tracking | both | Tap to focus, long-press AE-L, tap a face, double-tap for object tracking; zoom chip, pinch, disc; FOCUS tile; APERTURE on Action 6. | Same as `main`; zoom limited per FORMAT | Apple camera control owners (`OpenCineDJIApple`) |
| P4 | Gimbal | both | Joystick (size, invert, dead zone); Mode, Speed, Ramp; double-tap Recenter or Level; Motion Control A/B/C with Loop; game controller. iOS: AirPods head tracking. | Same motion as `main`; gimbal stops when you let go | Gimbal control owner (`OpenCineDJIApple`), `OpenCineMotion` |
| P5 | Audio meters | both | AUDIO on a body with a mic. | Levels move with sound, same ballistics as `main` | `MonitorUI` audio meter |
| P6 | HDR display, Photo mode | both | HDR display on; switch to Photo, press the shutter. | Record button acts as shutter; photo lands on the camera | Common control seam |
| P7 | Multiview | both | Grid icon → network → 2, 3 and 4 cameras; Record all; per-tile record; Camera settings panel; Grid and Center stage. | Each tile shows its own result; a camera in Photo mode disables Record all | `OpenCineMulticam` (stage still landing: multicam lane) |
| P8 | Share this feed / Watch a feed | iOS | Host with a passcode (QR); a second iPhone watches and requests control. | Watcher sees the feed and assists; control requests reach the host camera | `OpenCineRelay` (wire bytes unchanged) |
| P9 | Media extras | iOS | Bake LUT (+ exposure), Convert log, Frame.io. Android shares originals only. | Same as `main` | `OpenCineApple` exporter |

Intended differences (OpenPocketCine `docs/OPENCINE-INTEGRATION.md`, "What changes for
users"): cameras and pair pages are the shared flow; a Nano no longer shows a live timecode it
never reports; on Android the APERTURE sheet appears only on Action 6 and FOCUS follows the
body; the iOS HUD shows a pending value until the camera answers; Multiview record sends an
explicit start or stop per camera. The app's own detailed list: the "Physical device
checklist" in the same file.

## 5. OpenInstaCine

Camera: Insta360 Luna Ultra (firmware 1.1.15), 720p HEVC live feed at 25 fps. Force-quit the
Insta360 app on every nearby phone before pairing. No Multiview (not supported for Luna).

| # | Check | Platforms | Steps | Expected | Changed |
|---|---|---|---|---|---|
| I1 | Saved approval | both | Relaunch and reconnect; then delete and reinstall the app. | No camera prompt on reconnect; after reinstall the camera asks again (new identity) | Luna session (`Insta360Apple`, `insta360-luna`); keychain service unchanged |
| I2 | Reconnect timings | both | Wi-Fi off mid-live, back on; Bluetooth off. | "Reconnecting", then "Connection keeps dropping" at about 45 s with Retry. Android: live again in about 30 s with no tap; Bluetooth off keeps live over saved Wi-Fi (about 8 s) | Same |
| I3 | Modes and capture | both | Record in Video, Timelapse, TimeShift, Slow Motion, PureVideo; take a Photo. | Lamp waits for the camera, timer runs, stop saves a file | Common control seam (`OpenCineCore`) |
| I4 | Camera settings | both | ISO Auto/100-6400 (incl. 160); shutter 1/8000-1/5 and angle; WB Auto/2000-10000 K (applies 3.5-5 s later, dial holds); EV in thirds; FORMAT drum; Standard, I-Log, Dolby Vision; METER Matrix/Face. | Values match what the camera reports | Same |
| I5 | Focus, zoom, Deep Track | both | FOCUS AF-S, AF-C, Product Showcase; tap focus; long-press locks the box; zoom 1/2/3/6/15x and pinch; Deep Track by double-tap, drag or face. | Search box turns green on lock; zoom readout reaches 15x (was clamped to 12x in readouts) | Zoom and focus with common receipts |
| I6 | I-Log look | both | LUT → Auto on I-Log. iOS: flat I-Log preview preference. | Official I-Log to Rec.709 look ("Auto · I-Log → Rec.709" on Android) | `OpenCineMedia` (golden I-Log anchors) |
| I7 | Gimbal | both | Stick and game controller; Roll Lock, Roll & Tilt, FPV, FPV-V; speed; Recenter; Flip; Double-tap Level; Motion Control A/B/C. iOS: AirPods head tracking. | Level within 0.4° in about 2 s; Motion Control counts down, loops, pauses, stops | `OpenCineMotion`, shared motion settings |
| I8 | `.lrv` media | both | Album thumbnails (proxies hidden), download an original, play a `.lrv` with scopes and LUT, delete. | Delete also removes the `.lrv`; cached clips play offline | Luna media producer, shared library and playback |
| I9 | Watcher relay | iOS | Settings → Sharing hosts with a passcode; a second iPhone uses Watch a feed and requests record, focus or exposure. | Host grants; Android Sharing tab says "Coming soon" | `OpenCineRelay` |

Intended differences (OpenInstaCine `docs/implementation/opencine-integration.md`, "What
changes for users"): the pair page rail is "Find your camera" then four connect steps; a nearby
card reads "Ready to pair"; iOS offers Open Settings when Bluetooth is off; Clean view has no
AUDIO pin (Luna reports no audio levels); with no camera connected, iPhone Settings shows no
gimbal, joystick, head-tracking, zoom chip or timecode rows. Not on Luna at all: live audio, aperture,
AE/AWB lock (main never offered them; ignore the opposite line in the app's checklist).
A saved camera that still carries a hotspot setup connects from that chip over the camera's
own Wi-Fi, without main's "Turn on Personal Hotspot" prompt. On main no Insta camera could add a
hotspot setup, and the prompt (reached only from simulator review data) asked for a hotspot Luna
then ignored.

## 6. OpenZCine

Cameras: Nikon ZR, Z9 and Z5II work on `main`; Z6, Z6II, Z6III, Zf, Z8, Z7 and Z7II were
never tested there. Transports: camera access point Wi-Fi (OCR scan of SSID and key, or manual),
router, phone hotspot, USB-C; HDMI capture (UVC) as a picture source on iPad and Android. iOS
17+, Android 10+ (arm64).

New for Nikon testers: the cameras page, pair page, live chrome, Operator Setup, media catalog,
playback, delivery popup and Multicam come from the shared UI; Nikon keeps its gold accent and
its own controls in the shared screen's typed slots (capture, tools, panels).

| # | Check | Platforms | Steps | Expected | Changed |
|---|---|---|---|---|---|
| N1 | Every transport | both | Pair over camera Wi-Fi (scan and manual), router, hotspot and USB-C. iOS: the AccessorySetupKit Wi-Fi join. | PIN confirms on the camera; a saved setup appears; live view starts | Shared cameras and pair pages over `NikonIntegration`, `NikonDiscovery`; transports in `OpenCineNikon` |
| N2 | Passive discovery | both | Keep the cameras page open for 2 minutes while another phone has a live session on the same body. | The other session survives; while browsing the app never opens the PTP/IP control port or sends a PTP byte (only mDNS and the app's relay presence port 15741) | `NikonDiscovery` (`OpenCineNikon`, `nikon`) |
| N3 | Reconnect | both | Pull USB-C or power-cycle the body during live view; a failed first connect. | Last frame stays, marked as held, during a bounded reconnect; then Retry connection or Operator menu; first-connect failure offers Try again | Typed Nikon reconnect decision; shared frame runtime holds the frame |
| N4 | HDMI capture | iPad, Android | Plug a UVC capture device, then unplug it. | HDMI picture shows; unplug recovers cleanly | `OpenCineApple` UVC source (iOS) |
| N5 | DISP and framing | both | DISP 1, 2 (clean, per-tool pins), 3 (command dashboard, timecode keeps running); per-element display switches; pinch zoom with tap focus following it; vertical camera with Auto-Rotate Feed. iOS: Feed Upscaler, Feed Noise Reduction. | Same tools as `main`, in the shared chrome | Shared `MonitorScreen` with Nikon slots (`NikonCommandControls`, `CommandGrid`) |
| N6 | Focus dial (MF strip) | both | Turn the Focus dial on in the FOCUS popup; drive focus in video and photo; release; tap to focus; focus reset. | Focus moves by wire; release does not re-AF | `MFDriveVerticalScrub` / `MFDriveStrip` in the tools slot |
| N7 | e-VR | both | iOS: VR / e-VR panel. Android: DISP 3 tile. Try with a RAW codec. | Toggles on the body; disabled for RAW codecs | Nikon panels slot |
| N8 | Camera settings | both | ISO (Auto ISO, R3D NE Low/High base), shutter angle, iris, WB (presets, Kelvin, fine, tint), exposure mode, codec and 8/10-bit, resolution/fps, AF mode, area and subject, metering, audio, picture control. | Pickers mirror the body; values match the body; clock syncs on connect when drift is over 5 s | Common seam for ISO, WB and record; exposure descriptors for common controls |
| N9 | Photography mode | both | Shutter, hold for burst, bulb/time, timers, EV meter, instant playback, burst stacks; fire a shot on the body itself. | Same as `main`; body-fired shots appear | `NikonCaptureAction` in the system slot |
| N10 | Nikon assists | both | Audio meters, aspect markers, custom frames, split compare, RED LUTs and the in-app RED LUT download, de-squeeze 1.6x and custom 1.00-2.00x; each in live and playback. | Same as `main` (Android peaking is grainier, as on `main`) | Shared native frame and effects runtime; scopes moving in the nikon-assists lane |
| N11 | Media | both | Both cards; Photos and Videos tabs; `.HIF`; RAW+JPEG pairs; set a rating; slow-motion conform preview in playback. | Ratings land on the card; pairs stay together | Nikon catalog producer, shared library and conform math |
| N12 | Delivery | both | LUT-baked Share; Frame.io; internet hop while on the camera's Wi-Fi. | Upload completes and returns to the camera network | Shared exporter (Android owner emulator-verified only), `OpenCineFrameIO` |
| N13 | Share This Feed and remotes | both | Broadcast with a passcode, watch from a second phone, hand control over; record from Apple Watch, Wear OS, a Bluetooth shutter and a relay viewer holding control. | Each remote records the camera it shows; refusals put the button back | Relay record targets, watcher authority |
| N14 | Multicam (new, not on `main`) | both | Multicam with 2 to 4 bodies over router, hotspot or USB; group record; member control; try a camera Wi-Fi setup, HDMI, the same body twice and a fifth body. | Group records; the refused cases are refused with a reason | `OpenCineMulticam`, `NikonMulticamPolicy`, budget of 4 (stage still landing: multicam lane) |

Intended differences (OpenZCine `docs/OPENCINE-INTEGRATION.md`, "What changes for users"):
the shared screens above replace Nikon's own; the cameras page loses the camera border color and
icon; the full-screen connect card is gone; the live viewport changed with the shared chrome;
Operator Setup has the shared tabs. The app's detailed list: the "Physical device checklist"
(items 1 to 29, Multiview, performance baselines, Z-1a) in the same file.

## 7. What is verified and what is not

| Area | Verified by | Physical |
|---|---|---|
| OpenCine shared code | `swift test` 2339, Android unit 1204, strict concurrency, iOS builds of `MonitorUI` and `OpenCineApple`, Vulkan sync regression, atlas check | n/a |
| OpenPocketCine | `swift test` 280; iOS 752 XCTest on a private simulator; Android 539 unit tests, lint, debug and release APKs; watch build; relay 12 | untested |
| OpenInstaCine | `swift test` 591; iOS 563 tests on a private simulator; Android 687 unit tests and lint (insta lane, on the union with its fix `5e0ac3f`) | untested |
| OpenZCine | `swift test` 626; iOS 206 XCTest + 105 Swift Testing on a private simulator; Android 1002 unit tests, lint, APKs; native readable export device test on an emulator; Vulkan pixel parity on an emulator | untested |
| Live picture, Metal and Vulkan | Simulator Metal and emulator SwiftShader only | untested on real GPUs |
| Bluetooth, Wi-Fi join, hotspot, USB, PTP | Unit tests with fakes; not possible on simulators | untested |
| Multiview with 2 and 4 cameras | Simulated scenarios on the shared engine | untested |

Known open items at this snapshot:

- **Insta Android playback is black on the emulator** (also on Insta `main`): the shared
  Media3 port prepared the player before the picture surface attached. Fix in the insta-black
  lane; Pocket's playback port has the same ordering. Check C15 on Android with care.
- **OpenInstaCine at `67c42504` needs the insta lane's `5e0ac3f`** to build for the Simulator
  against OpenCine `6133cf67` (a simulator-only gallery fixture); device builds do not compile
  that file but were not tried at this exact pair.
- Android movie export and LUT bake are not offered in Pocket and Insta (they share originals),
  as on `main`.
- Still landing: Pocket iOS `CameraSession` compatibility owners, Multiview stage composition
  (Pocket, Nikon), Insta session compatibility and its remaining copy of Pocket's view core,
  Nikon assist and inspector owners. See [Not retired yet](RETIRED-OWNERS.md#not-retired-yet).
- App pins are stale (see [Revisions](#revisions-under-test)); a CI checkout of an app at
  `integration/thin-app` would fetch the old pin and fail to compile.
- Flaky, pre-existing: OpenCine XCTest `MonitorReaderWriterMediaExporterTests` (truncated-input
  reads are nondeterministic). Nikon `swift-format` lint reports 628 formatting-only findings.

## 8. Report a regression

For each failure, note:

- app, platform, phone model and OS version, camera model and firmware;
- the four revisions you built ([Revisions](#revisions-under-test)) and whether `main` of the
  same app on the same phone and camera behaves differently;
- the check number (C7, P3, ...), the steps, what you saw, and a screen recording or
  screenshot; Share Diagnostics output for connection or picture problems.

An issue in shared behavior (any C check, or an owner named in "Changed") belongs in OpenCine;
an issue only in an app's own panel belongs in that app.

## 9. Refresh this guide

For the final pass, after the remaining lanes merge:

1. Update [Revisions](#revisions-under-test): `git -C <repo> rev-parse --short=8
   integration/thin-app` in all four, and the pin columns (or remove them once pins move).
2. Update the counts in section 7 from the final combined run (finish.matrix), and remove
   known open items that closed.
3. Rerun the refresh commands in [RETIRED-OWNERS.md](RETIRED-OWNERS.md#refresh) and update its
   tables and [Not retired yet](RETIRED-OWNERS.md#not-retired-yet).
4. Add checks for anything new the lanes ship (for example Nikon scopes and Multiview stage).
