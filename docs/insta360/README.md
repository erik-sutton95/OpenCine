# OpenCineInsta360

The Insta360 Luna integration for OpenCine apps: wire protocol, Apple I/O adapter and the
OpenCineCore `CameraSession` for Luna. Extracted from OpenInstaCine (VENDOR-03).

## Products

| Product | What it holds | Imports |
|---|---|---|
| `Insta360Protocol` | UCD2 framing, protobuf, Luna requests/status/schema tables, gimbal pose, screen wire. Pure Foundation, builds and tests on macOS. | Foundation |
| `Insta360Apple` | `LunaCameraBackend` (BLE consent, encrypted Wi-Fi credential handoff, camera Wi-Fi join, TCP 6666 control and HEVC preview, media), `LunaCameraSession` (`OpenCineCore.CameraSession`: ISO, shutter, white balance, record with readback confirmation; publishes host-derived timecode (`ingest(timecode:)`, origin `.clockDerived`) and no audio levels; `LunaCameraSession.motion` is the gimbal with camera-reported pose; `layout(base:)` is what a monitor lays out, with zoom and focus still on until the session routes them), the `CameraBackend` discovery/connection/picture/media seam, `LunaIntegrationConfiguration`. | Insta360Protocol, CKcp, OpenCineCore, OpenCineMotion, OpenCineMedia, Apple frameworks |
| `Insta360AppleTestSupport` | `FakeLuna`, a scripted camera behind a session's link. Test targets only. | Insta360Apple |

`CKcp` (internal C target) is KCP plus two shims (`luna_kcp_*`, `luna_add_ipv4_alias`).

## Using it

```swift
let backend = LunaCameraBackend(configuration: .init(
    keychainService: "org.example.mycine.camera", appName: "MyCine", logPrefix: "MyCine"))
let session = backend.openSession()   // one OpenCineCore session per connection
```

Every instance owns its own link, session, credentials store and callbacks; nothing is
process-wide except the phone's single camera access point (192.168.42.x, `LunaWiFi`), a
qualification limit: two simultaneous Luna connections are unsupported.

`LunaIntegrationConfiguration.keychainService` defaults to `org.opencine.openinstacine.camera`
so OpenInstaCine's saved authorization identity and camera Wi-Fi keep working. Another app must
pass its own service.

Known limits (keep them visible as capability results, not hidden): no live audio, Multi View
unqualified, `LunaScreenRecovery` (Color Recovery over KCP) has no caller yet. iOS-only APIs
(NEHotspotConfiguration) compile only for iOS devices; macOS and the simulator ask the operator to
join the camera Wi-Fi.

## Integration contract (SHELL-02)

`LunaIntegration` (Swift `Insta360Apple`, Kotlin `insta360-luna`) is Luna's Core
`CameraIntegration`, over a `LunaConnectPort` that `LunaCameraBackend` / `LunaBackend` implement:

- Discovery is `.passive` only: Bluetooth advertisements (service BE80); listening never connects.
  iOS sightings are named like the cameras page always named them (`title(advertised:)`, "Luna
  Ultra 1A2B" from an advertised "1A2B") with the profile title as the model. A scan that cannot
  start (Bluetooth off or not allowed) keeps discovery subscribed and is published as
  `discoveryFailure` / `onDiscoveryFailure` for the app's pairing slot; `retryDiscovery()` starts it
  again.
- One connection at a time (one backend): a newer attempt ends the older one. Steps are the connect
  card's ("Connecting over Bluetooth", "Joining camera Wi-Fi", "Opening the video link", "Starting
  the picture"); phases follow `LunaCameraSession`; prompts are `approveOnCamera("Approve on the
  camera")` and `acceptNetworkJoin(network:)` (iOS: the attempt-3 Settings note replaces its text).
- Failures are typed `ConnectionFailure`s with unchanged copy: Swift at every connect throw site
  (Bluetooth power and permission offer Open Settings; the failure reads as its message through
  `LocalizedError`, so callers that show `localizedDescription` are unchanged); Kotlin where the
  backend chooses its copy by phase (`LunaFailures`, also `LunaBackend.failureDetail` beside the
  unchanged `failure` string). A Swift attempt failure that times out or drops reads as
  OpenInstaCine's cards always showed it (`operatorMessage`, its former `friendly()` rules); the
  Android rules match no Luna copy, so Kotlin keeps the backend's text.
- A connect yields the saved record (camera access point as the preferred route with the joined
  network; iOS also the verified serial as the durable device) and the core session.
- `forget` drops the camera's saved Wi-Fi (Swift: the Keychain entry; Kotlin: the host's
  `forgetWifi`), never the approval identity. Every backend event is also forwarded to
  `LunaIntegration.onEvent` (Swift) for the app's live view.
- Tests: `LunaIntegrationTests` / `LunaIntegrationTest` against `FakeLunaPort` (Swift test support,
  Kotlin test source), same method names.

## Optional connected-camera media service

The successful connection registers its real media producer as `CameraMediaService` in
`ConnectedCamera.services`. The connection port may omit it; no common shell downcast or
manufacturer selection supplies a default. Swift app ports pass through the backend producer;
Kotlin delegated ports implement `CameraMediaServiceSource` from `insta360-shell`.

The producer owns one browse lease across nested covers and rotation. Catalog refresh replaces
only its pull cursor. Close retires work before yielding and performs the existing stop/access/start
return sequence only while its captured session, control epoch, connection and browse owner remain
current. Every protocol hop checks that authority, and commands use `LunaCameraSession`'s actual
transport/lifetime. No ACK becomes a fresh-picture or confirmed-delete observation.

Catalogues enumerate internal storage (location 2) and an inserted SD card (location 3),
using source-fenced storage inventory and per-location listing and metadata requests. A full or
write-protected card remains readable. Unknown or unsupported inventory probes the SD listing;
only an explicitly absent card skips it. Paging follows the camera-reported totals, including
proxy files, and deduplication uses complete camera URIs so identical filenames on different
storage remain distinct. A failed, retired or cancelled query cannot publish a partial replacement.
When inventory is unknown and the SD query fails, the refresh fails rather than presenting an
internal-only list as complete. Kotlin checks the original caller cancellation at reply and
publication boundaries as well as the native owner lifetime.

`OpenCineMedia` defines opaque assets/representations, bounded upsert/removal pages, native staging
sinks and optional thumbnail/transfer/delete operations. Native IO is supplied by `LunaMediaIO`
(Swift) or the existing thumbnail codec plus `LunaMediaTransferPort` (Android). Unimplemented IO
is absent; source requests/addressing stay in the integration. The runtime preparation callback
must independently validate the captured native/session owner. The source never imports the
neutral Apple runtime, AppKit or UI. Current native camera/device behavior remains untested.

## Deep Track and tap focus

`LunaSubjectTracking` (Swift) owns one connection's Deep Track boxes and tap focus. It reads the
camera's 0x85 track frames and 8315 notifications, and sends cmd 237, the tracking cancel and the
tap-focus ROI only through `LunaCameraSession` while that session is ready and owned. Control
admission, notes and face boxes stay in the app. Kotlin `LunaSubjectTracking` (insta360-luna) is its
twin over the backend's `CameraControls`, which builds the wire rectangles; the Android app keeps its
start policy (ignore the previous subject until one near the new box).

Requests the common model does not describe yet (gimbal, clock sync, keyframe and photography
options) use `LunaCameraSession.control(_:timeout:)`, which sends only while the session is ready
and owned and passes the caller's timeout to the backend. On iOS the app sends nothing through
the backend directly; a DEBUG-only lab probe is the one exception.

## Gimbal motion

`LunaMotionService` (Swift) is the Luna gimbal on the session's control path: the held stick
repeats cmd 226 MOVE every 50 ms (a held stick at rest keeps repeating MOVE 0, 0, which is the
release request itself), single steering MOVEs, release, recenter, flip, SET_ANGLE with yaw wrapped
and pitch kept inside `LunaCameraSession.motion`, and GET_ANGLE as `latestPose`. It implements the
shared `MotionService` over those requests; `move(to:over:)` accepts only `over: nil`, because the
camera plans each SET as its own move. The app runs aim until arrival, head tracking and
programmed moves against its live state, on shared math: `LunaMotionService.hasReached` (arrival
within the declared tolerance on each axis), `LunaHeadTrackSteering` (the stick toward the AirPods
head from GET_ANGLE and a model of the sent stick), OpenCineMotion's `HeadTrack.reference` (the
head's fitted angle, rate and acceleration) and `GimbalProgram.pose(at:)`. Kotlin `LunaMotionService` (insta360-luna) is its twin over the backend's
`CameraControls` (the stick stream at 50 ms, release, recenter, flip, SET_ANGLE, GET_ANGLE as `poses`,
and `hasReached`); the Android app keeps its aim, level and programmed-move loops the same way,
on core motion's `GimbalProgram.pose` and `duration`.

## Clock and timecode

The Luna's timecode is time of day from its own clock, which the phone sets.
`LunaCameraSession.syncClock()` sends the official app's clock SET (options 12, 13 and 175), then
cmd 214 twice, each stamped at send, on the control path (Android: `LunaBackend.syncClock`).
`LunaFrameTimecode` turns live frame stamps into that timecode: the frame clock does not follow
the camera's time of day, so frames are pinned to the phone clock by their earliest arrival (less
90 ms of capture latency), and a new value is reported once a second. Kotlin
`LunaFrameTimecode` (insta360-luna) is its twin, in Android's millisecond clock with the zone
offset taken at the frame's time of day.

## Common lens controls

`LunaCameraSession.configureLens(zoomDomain:)` (Kotlin `configureLens(range)`)
describes the connection's configured zoom range, within the protocol's 1...15
range. An absent or invalid range leaves zoom support unknown. The backend
configures its existing maximum; an app can supply its own connection ceiling.
Zoom and AF-S/AF-C use the common setting commands and camera-authored readbacks.
Acknowledgement is pending until observation; a ramp confirms within the existing
0.05 zoom tolerance. Changing the range invalidates editors from the old capability
revision. Unreported lens values remain unknown.

Product Showcase (option 93 value 6) remains an integration-owned focus extension,
never a substitute for the common continuous focus observation. Partial replies
preserve unrelated values; an explicit missing/invalid lens reply clears that
observation. Closing or replacing a session cannot confirm a late old command.

## Import rules

- No UI: never import SwiftUI, UIKit or OpenCineUI.
- No app types and no brand: app names, keychain service and log prefix come from
  `LunaIntegrationConfiguration`.
- Depends only on `OpenCineCore` (same package; root `Package.swift`).

## Build and test

```sh
swift build && swift test --filter Insta360    # macOS: protocol, session, harness tests
xcodebuild -scheme Insta360Apple -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Hardware behavior (pairing, Wi-Fi join, settle timing) is qualified only on a physical Luna Ultra
through the consuming app.

## Kotlin (Android/)

Two modules of the platform Gradle build (`Android/` at the repository root: one wrapper and
version catalog, AGP/Kotlin matching the apps); `:insta360-shell` depends on `project(":core")`
and exposes `api(project(":media"))` for the real producer and streaming driver contracts.

| Module | Coordinate | What it holds |
|---|---|---|
| `:insta360-shell` | `com.opencapture.opencine:insta360-shell` | Kotlin/JVM app shell contract, the Kotlin twin of the Swift `CameraBackend` seam: `CameraBackend` (discovery, connection, frames), `CameraControls` (Luna live controls), `CameraMediaStore`, `CoreSessionSource` (hands out the OpenCineCore `CameraSession`) and their Luna-shaped values. Package `com.opencapture.opencine.insta360.shell`. |
| `:insta360-luna` | `com.opencapture.opencine:insta360-luna` | Android library: `LunaBackend` (BLE, camera Wi-Fi, TCP 6666, HEVC preview, media), `LunaCameraSession` (OpenCineCore session; like Swift it publishes host-derived timecode through `ingest(timecode)`, no audio levels, the gimbal as `LunaCameraSession.MOTION`, and `layout(base)`), wire/status/IMU code. Package and namespace `com.opencapture.opencine.insta360.luna`. compileSdk 37, no AAR-metadata exemption. |

The shell contract is not in OpenCineCore: its values are Luna-shaped (shooting, gimbal and focus
modes, program and storage codes) and Core already owns the neutral command and state contract.
Moved from OpenInstaCine `:core-api` and `luna-adapter` (CORE-API); OpenPocketCine's
`ConnectionPhase` stays with the DJI integration.

`LunaBackend(context, savedWifi, saveWifi, clientIdentityPreferences)`: the last argument names the
SharedPreferences file holding the camera authorization identity. Its default
`openinstacine.client-identity` keeps OpenInstaCine's saved approvals; another app passes its own.

```sh
cd Android && ./gradlew :insta360-shell:test :insta360-luna:test :insta360-luna:lint :insta360-luna:assembleRelease
```

A consumer includes the platform build by name and substitutes both coordinates (plus any other
OpenCine modules it uses, in the same block):

```kotlin
includeBuild("../../../OpenCine/Android") {
    name = "opencine"
    dependencySubstitution {
        substitute(module("com.opencapture.opencine:insta360-shell")).using(project(":insta360-shell"))
        substitute(module("com.opencapture.opencine:insta360-luna")).using(project(":insta360-luna"))
    }
}
```

## License

Apache 2.0 (root LICENSE, NOTICE). KCP and the Luna protocol reference are MIT
(root THIRD-PARTY-NOTICES.md, `Sources/CKcp/LICENSE`).
