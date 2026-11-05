# OpenCine desktop: dock, camera modules and one shared webcam driver

Status: draft for owner review, 2026-11-05.
Scope: Mac first. Windows and Linux are the follow-on project and reuse the product shape, not this
code. RTMPS (`docs/superpowers/specs/2026-11-05-rtmps-streaming-design.md`, on its own branch) comes
after this and is parked.

Marking: **[Owner]** was decided by the owner. **[Call]** is the author's call, open to correction.
Unmarked text describes the existing code.

## Intent

A person with an Insta360 Luna, a DJI Pocket and a Nikon Z installs one desktop app, OpenCine. Each
camera is a module that appears as a tab, and each connected camera appears as its own video input in
OBS, Zoom or any other app, through one driver installed once. That makes a three-camera podcast or
Twitch setup possible with OBS doing the switching.

Why now: the owner has a podcast in 3 to 6 hours and wants this done properly rather than patched.
**[Owner]** Only the Nikon Z must be live on that podcast.

## Goals

- **[Owner]** One desktop-only app, OpenCine. Phones keep their separate apps.
- **[Owner]** Downloading any thin app on desktop gets you the dock with that app's camera.
- **[Owner]** More cameras can be downloaded from inside the dock, each becoming a tab.
- **[Owner]** One driver, installed once. Three connected cameras show as three separate inputs.
- **[Owner]** Same webcam capability as the OpenZCine prototype, for all three cameras.
- **[Owner]** Mac, Windows and Linux are all wanted. **[Call]** Mac ships first; the others are next.

## Non-goals for this project

- **[Call]** Windows and Linux builds.
- **[Owner]** RTMPS streaming and switching. OBS switches.
- **[Call]** Sync between webcam inputs. OBS sees each camera as it arrives.
- **[Call]** Audio through the driver. Webcam inputs are picture only; audio comes from the Mac's
  own audio devices, as with a physical webcam.
- **[Call]** Several inputs per module. Each module publishes one input in the first release, its
  selected camera, even where the app supports multicam.

## Anti-goals

- Breaking the working fallback. The installed OpenZCine app and its active driver stay in place until
  the new setup is verified on the owner's machine. The new driver has its own bundle identifier, so
  both can coexist.
- One camera taking the others down mid-recording.
- Claiming a working webcam because the extension activated. Only received frames prove it (a lesson
  from the October work, where activation and output were separate failures).
- Forking app code for Mac. Every surface stays the shared component (`parity means shared components`).
- Reinstalling the driver casually. October found a macOS replacement race.

## What exists today

| Piece | State |
| --- | --- |
| Driver (extension, 436 line provider) | October, in the archive: `git/untracked/ssd_lanes_MacZRebuild-20261022_OpenZCine.tgz`. Fixed single device, one source and one sink stream, 1920x1080 BGRA at 30 or 60 fps, bounded queues, slates, epochs. Active on this Mac as extension 15 |
| Producer (`MacVirtualCamera.swift`, 627 lines) | Same archive. Feeds the sink across processes |
| Policy (`macos/CameraPolicy`) | Same archive, with tests |
| Z Catalyst port | Patch in `git/patches/wt_OpenZCine_..._mac-catalyst-rebuild-20261022.patch`, plus Core commit `f6dba6d52` in the repo. Both are from 2026-10-21 and need rebasing |
| Pocket and Luna on Mac | No project enables Catalyst. `/Applications/OpenPocketCine.app` is a debug Catalyst build from 2026-09-21 (`com.opencapture.openpocketcine.mac`), source not found, and the owner does not recall whether it showed live video. Launch it once to find out when a Pocket is available |
| Dock, module loading, downloads | None |
| Signing | Team `4V4EGQ6LZA`. This Mac has Apple Development and Apple Distribution identities, and no Developer ID |

## Product behavior

### The dock

OpenCine opens one window with a tab per installed module and a **+** tab to add a camera. A tab shows
that camera's normal monitor and controls, the same shared UI as its phone app. All connected modules
keep running and feeding their input whether or not their tab is showing. **[Call]** Closing the window
asks first if any input is in use; quitting ends every module.

### Inputs

- **[Call]** Each module gets a stable input named after what it is: `OpenCine Nikon Z`, `OpenCine
  Pocket`, `OpenCine Luna`. The name and device ID never change, so saved OBS scenes find it again.
- **[Call]** An input exists while its module is installed, rather than appearing and disappearing with
  the connection. This corrects the earlier guess: receiving apps cope badly with devices that vanish
  mid-session, and a stable device shows a clear slate ("Pocket not connected") until the camera connects.
- **[Call]** Output stays 1920x1080 BGRA at 30 or 60 fps as negotiated by the receiver. Smaller sources
  are fitted without cropping, with bars, and never presented as more than they are in the UI.
- The picture is the clean feed, with the selected LUT and no monitor overlays, as in October.
- A per-module **Webcam output** switch, on by default in the dock.

### Connection

The Mac has one Wi-Fi radio, so three cameras cannot each use their own hotspot. The dock explains this
when a second camera tries. **[Call]** Supported for first release:

| Camera | Routes on Mac |
| --- | --- |
| Nikon Z | Shared network or camera access point, USB (to be tested), HDMI capture for picture |
| Pocket | Bluetooth plus a shared network or the camera's Wi-Fi. Bluetooth is required on every route |
| Luna | Shared network, or the camera's Wi-Fi with a saved authorization |

A three-camera setup needs a router or phone hotspot that all three join. The Mac cannot join networks
for the user in every case; where it cannot, the app says which network to choose in System Settings.

### Adding a camera

**[Call]** The **+** tab lists cameras from a signed catalog. Choosing one downloads the module, verifies
it and adds the tab with no reinstall of the dock. A thin app's desktop download is the same OpenCine
with that module included; if OpenCine is already installed, it only adds the module.

The first build's modules are built and installed locally. Public downloads wait for the Developer ID
step and for the hardware pass (the standing release gate).

## Architecture

### One process per module

**[Call]** Each camera module is its own signed Mac Catalyst app bundle, stored inside the dock's
modules folder and run without its own Dock icon. The dock is a small native macOS app. It owns the
tab strip, installs the driver, and starts and coordinates modules.

Why this, and not loading all cameras into one process:

- **Isolation:** one camera crashing leaves the other inputs live. That is the whole point for a podcast.
- **No conflicts:** the apps share defaults keys (`opc.*` in Pocket and Luna), start Sentry once per app,
  read `Bundle.main`, and use process-wide statics such as `MonitorTheme.accentRGB`, the Nikon connection
  log hook and the USB browser singleton. Separate processes need none of it changed.
- **Thin apps stay thin:** the same app target builds for iPhone and as a Mac module.
- **Permissions:** Bluetooth and local network stay per module.
- **Cost:** a real tab inside one window is not possible across processes on macOS, so tabs are
  coordinated windows (below). It uses more memory than one process.

### Tabs

Module windows stay exactly aligned under the dock's strip; switching tabs brings the chosen window
forward at the same frame. Hidden modules stay running with App Nap disabled. To the user it looks like
one window with tabs.

**This is the design's main technical risk, so it is proven first (Spike 1).** If the swap feels wrong
or a hidden module stops producing frames and cannot be fixed, the fallback is plain side-by-side
windows from the same dock, keeping everything else in this design. The in-process route is a last
resort because of the conflicts above.

### Frames without a visible view

Today, Nikon stops live view on background, and DJI and Luna only produce a `CVPixelBuffer` once
VideoToolbox owns decode, which unlocks after a presented picture. Hidden modules need neither to apply:

- A neutral demand (beside `MonitorVideoDemand`) requests decoded frames while webcam output is on.
- `MonitorLiveVideoRuntime` feeds decode before a layer attaches.
- On Mac, a module's scene is treated as active while the dock owns it, so heartbeats and recovery keep
  running. The phone behavior is unchanged.

These are shared changes behind explicit host values, with iOS defaults unchanged.

### The driver

A new single extension, `com.opencapture.opencine.camera`, embedded in the dock, derived from the October
provider.

- **Devices:** **[Call]** a pool of 8 generic slots, each with a fixed UUID and legacy ID
  (`OpenCine.Camera.1` and so on), a source stream and a sink stream. The October safety rules move per
  device: one producer, epochs, bounded queues, slates. The driver names no manufacturer, and a new camera
  type needs no driver update, which keeps "installed once" true alongside downloaded modules.
- **Slot table:** **[Call]** the dock assigns each installed module a slot permanently, and writes slot
  number and display name to a table in the shared app group container. The extension publishes only
  assigned slots, using the name from the table. Device IDs never change, so saved OBS scenes find them
  again. If live table updates prove unreliable, the extension reads the table at start, and a new module's
  input appears after the extension restarts, not through a reinstall.
- **Identity limit, kept from October:** CMIO admission is the only producer check. It is not a
  cryptographic proof of who is feeding a sink. This is acceptable for a local webcam and is documented.
- The driver is approved once, by the user, in System Settings.

### Code layout

Within `AGENTS.md`'s boundaries:

- **`OpenCineVirtualCamera`** (Apple, new): the producer, the policy from `CameraPolicy` and the slot table.
  No UI, integration or app.
- **`OpenCineDesktopKit`** (Foundation only, new): module manifest, catalog parsing and verification rules,
  dock and module coordination messages. Portable, so Windows and Linux can use it.
- **`Desktop/`** in the OpenCine repo (new): the dock app and the driver extension, which name no
  manufacturer. **[Call]** No new repository, since the dock is the platform.
- **Each thin app:** Catalyst enabled on its existing target, with Mac guards around iPhone-only setup.
  Module identity arrives as host values. Known work:
  - AccessorySetupKit: guard it in Nikon's unguarded file.
  - MetalFX: guard or link conditionally, to be confirmed by build.
  - DJI's hotspot join: add a "choose in System Settings" path, as Luna has.
  - `en0` hardcoded in the DJI and Luna shared Wi-Fi paths: find the Wi-Fi interface instead.
  - Hotspot entitlements: drop from Mac builds.
  - Sentry on Catalyst: confirm by build.
- **Coordination:** dock and modules talk over a local socket in the app group container, using
  `OpenCineDesktopKit` messages (show, hide, frame, status, quit). Sandboxed on both sides.

### Module package and catalog

**[Call]** A module is a signed, notarized app bundle in a versioned archive with a manifest (ID, name,
version, minimum dock version, SHA-256). The catalog is a signed JSON file on GitHub Releases. The dock
checks the catalog signature, the hash, and that the bundle's Team ID is `4V4EGQ6LZA`, then installs under
its modules folder. Modules and dock update separately, within the version range in the manifest.

## Owner-dependent steps

| Step | Why | When |
| --- | --- | --- |
| Approve the new driver in System Settings | macOS requires it | Once, first run |
| Possibly enable capabilities for new App IDs in the Apple portal | System extension and app group on `com.opencapture.opencine*` | Before the first signed build, if Xcode cannot do it alone |
| Create Developer ID certificates | Public downloads need Developer ID plus notarization. Not needed for this Mac | Before public release |
| Have all three cameras and a shared network | End-to-end test | Hardware pass |

## Delivery order

1. **Spike 1:** rebase the October Z port, build it as a module, and prove a hidden module keeps feeding,
   and that the tab swap feels right. Decides the tab design.
2. **Driver:** shared `OpenCineVirtualCamera`, new extension with per-module devices, proven with
   simulated producers feeding three inputs into a receiver at once.
3. **Dock:** tabs, driver install, module start and status, locally installed modules.
4. **Modules:** Nikon Z, then Pocket and Luna in parallel. First usable build on the owner's Mac as soon
   as a module works end to end; each added module extends it.
5. **Hardware pass:** three cameras into OBS on a live checklist page, including a one-hour soak, crash
   isolation and sleep and wake.
6. **Downloads:** catalog, verification, **+** tab, thin-app downloads, Developer ID and notarization.
7. Windows and Linux: a separate design.

**Podcast plan:**

- **[Owner]** The Nikon Z is the only must-have, so Pocket and Luna do not gate the show. They continue in
  parallel and join if verified.
- **[Call]** Tabs get an early try. If they are not solid by the halfway point, the dock ships the Nikon
  module in a plain window and tabs land after the show.
- **[Call]** Driver and dock changes on this Mac freeze 60 minutes before the show. The owner then runs one
  real test in the receiving app they will use, and picks the new Nikon path or the existing OpenZCine build.

**Cleaning up this Mac:** **[Owner]** "We can clear out all the old stuff." A restart clears the 8 old driver
entries waiting to uninstall, and the owner picks when, before the new driver is activated. **[Call]** The
September Pocket build is removed after its one test launch. The old OpenZCine app, `OpenZCine Camera.app` and
their driver are removed last, only once the new Nikon path is verified with frames, because they are the
podcast's fallback.

## Testing

Behavior tests per `AGENTS.md`:

- **Driver and policy:** the October policy tests move over, plus per-device isolation: one producer's
  loss or bad frames never affects another input.
- **Simulated producers:** three sinks fed at once, a receiver confirming unique frames on each device,
  and slates shown when a producer dies. Labeled SIMULATED.
- **Desktop kit:** manifest and catalog rules with golden files, including a bad hash, wrong team and a
  too-new minimum version.
- **Consumer checks:** iOS builds of all three apps unchanged, and `atlas check`, API snapshots and pins as usual.
- **Real receivers:** OBS, QuickTime and one video call app. Frames, not activation, are the proof.

## Left to the builder

- Exact coordination message shapes and the app group path.
- How the dock aligns module windows on Catalyst (AppKit bridge bundle or similar).
- The file split of shared code, as long as boundaries hold and `atlas check` passes.
