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
qualification limit: two simultaneous Luna connections over camera Wi-Fi are unsupported. Several
Lunas run at once only over Wi-Fi and hotspot setups (station mode); see
[Multicam over station routes](#multicam-over-station-routes).

`LunaIntegrationConfiguration.keychainService` defaults to `org.opencine.openinstacine.camera`
so OpenInstaCine's saved authorization identity and camera Wi-Fi keep working. Another app must
pass its own service.

Known limits (keep them visible as capability results, not hidden): no live audio, Multi View
not hardware-qualified (station routes only), `LunaScreenRecovery` (Color Recovery over KCP) has no caller yet. iOS-only APIs
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
- Wi-Fi and hotspot setups (station mode): the profile offers `.infrastructureNetwork` and
  `.phoneHotspot` as addable routes, and `connect` takes `.addRoute` and saved station routes
  through `LunaConnectPort.connect(to:route:)`. The backend authorizes over Bluetooth, reads the
  camera's own Wi-Fi (kept for the camera Wi-Fi route), then sends SET_WIFI_MODE 147 (station,
  with the camera's region from option 37), PHONE_INFO 220 and SET_WIFI_CONNECTION_INFO 112,
  waits for notification 8232 and sends SET_AVAILABLE_WIFI 215 (`LunaStation.swift`). The join
  (`LunaStationJoin`, Kotlin twin alike) follows the official app: a 112 answered 505
  (`WIFI_BUSY_SWITCHING`, the camera still switching roles) is sent again after notification
  8215 (`CAM_WIFI_START`, up to 38 s) and a 2 s settle; only an 8232 that echoes this join's
  network and password counts; a missing or transient result (TIMEOUT 1, CONNECT_FAILED 2,
  UNABLE_ASSIGN_IP 4) gets one more try. A setup saved without a password that is refused says
  to check the Wi-Fi password. The phone
  joins the network (or hosts the hotspot) and searches its subnet for TCP 6666 answering the
  UCD2 magic (`LunaStationPath`); control and HTTP media then use that address
  (`cameraHost`), with the Bluetooth serial checked as for camera Wi-Fi (both platforms read
  option 15 over Bluetooth and on the control link). Another camera on the same network is not
  the one asked for: its control link is closed after the identity read and the search goes on
  without it within the same 60 s. On that address the
  preview is H.264, which the shared decoders detect. Camera Wi-Fi after a setup sends 147 AP
  first. Passwords stay in the Keychain (`savedStations()`), and the shared rules for routes,
  stamping and failure actions are Core's `StationRoutes`, shared with DJI. Evidence: router
  join, LAN control and H.264 preview with the lab tools on firmware 1.1.15 (2026-10-01); the
  app path and the hotspot route are untested on hardware. The Luna has no verified network
  scan, so the wizard runs with `cameraScansNetworks: false`.
- Camera Wi-Fi checks the serial too: a link whose serial is not the one Bluetooth read fails
  with `wifi.serial-mismatch` on both platforms (Kotlin used to skip the check). Saved Wi-Fi
  without Bluetooth has no serial to check.
- `forget` drops the camera's saved Wi-Fi (Swift: the Keychain entry; Kotlin: the host's
  `forgetWifi`), never the approval identity. Every backend event is also forwarded to
  `LunaIntegration.onEvent` (Swift) for the app's live view.
- Tests: `LunaIntegrationTests` / `LunaIntegrationTest` against `FakeLunaPort` (Swift test support,
  Kotlin test source), same method names.

## Multicam over station routes

Several Lunas share one network only in station role: a router's Wi-Fi or this phone's hotspot.
The phone holds one camera access point at a time, so that route never joins a group.

- `LunaMulticamPolicy.qualification(route:device:members:)` (Swift `Insta360Apple`, Kotlin
  `insta360-luna`, twins with the same test names): no saved route is `.notReachable`; router and
  hotspot routes qualify, or are `.alreadyMember` when the camera is in the group; the camera
  access point and every other route are `.unsupportedConfiguration`. The member limit is the
  app's `ResourceBudget`.
- Each member has its own backend. `stationHostsInUse` (both platforms) gives a backend the hosts
  the app's other connections hold (their `cameraHost`); its search never probes them. The
  connect then ends on the camera it asked for: a host whose serial is another camera's is closed
  and skipped (`LunaStationPath.findRequestedCamera`, Kotlin `LunaStationSearch.findRequested`).
- Android: members pass one shared `SharedWiFiPath` as `LunaBackend(stationPath:)`. The path's
  join and process binding are held per backend and let go when the last one releases, so one
  camera's cleanup never unbinds another's network. A station connect never releases the camera
  access point joiner (that release unbinds the process).
- Connect members one at a time: a first connect commissions over Bluetooth (a reconnect goes
  LAN first, see below).
- Tests: `LunaStationPathTests` / `LunaStationSearchTest` (two cameras on one subnet, an in-use
  host never probed, a wrong camera skipped within the budget), `LunaDeviceIdentityTest` (Kotlin
  refuses a serial mismatch), `LunaMulticamPolicyTests` / `LunaMulticamPolicyTest`,
  `PathHoldersTest` (`:platform`). Untested on hardware with two or more Lunas.

### Multiview operations (hardware-untested)

What the shared Pocket-standard Multiview needs from the Luna (spec
`docs/superpowers/specs/2026-11-13-shared-multiview-design.md`, plan
`docs/superpowers/plans/2026-11-13-luna-multiview-prep.md`). Swift and Kotlin twins with the same
names; every behavior below is unit-tested against scripted links and fakes and **untested on a
camera**.

- **Return to its own Wi-Fi**: `LunaIntegration.returnToAccessPoint(_:)` (port and backend:
  `returnToAccessPoint(cameraID:)`, Kotlin `returnToAccessPoint(id)`) authorizes over Bluetooth,
  sends SET_WIFI_MODE 147 for access point mode (the camera's region from the credential read)
  and disconnects (`LunaAccessPointRestore`, over the same `LunaBluetoothAuthorization` a connect
  runs). The phone joins no network; the backend's own link ends first and nothing else is sent:
  no capture, record or live command (the tests record every request the camera receives). Pocket
  says "No stop-recording command is sent. Recording continues."; for the Luna the second half is
  an inference from sending only 147, not a hardware fact: whether a Luna keeps recording while it
  switches its Wi-Fi role is untested. The result is `LunaAccessPointReturn`: `returned`;
  `deferred` (Bluetooth could not reach the camera or dropped during authorization, reply 505 still
  switching, no answer) which the caller may retry, `LunaAccessPointReturn.retrying` (3 tries, 3 s
  apart on Android, like DJI's `restoreCameraWiFiWithRetry`); or `failed` (the camera declined this
  phone, another phone holds it, it is no supported Luna, or it refused the switch). The caller
  keeps the camera in its cleanup record until it returns. On Android the return runs as the
  backend's connection job, so a connect started meanwhile cancels it, and a caller that stops
  waiting cancels it too. Tests: `LunaAccessPointReturnTests` / `LunaAccessPointReturnTest`.
- **Open at a station address, LAN only**: `LunaCameraBackend.connect(to:at:on:)` (Kotlin
  `LunaBackend.connect(id, at, on)`) opens a camera at a `LunaStationHost` on a
  `LunaStationNetwork` with the serial check and no Bluetooth fallback (`LunaStationOpen`): an
  address from another network, without a proven serial or in `stationHostsInUse` is refused at
  once (Swift throws, Kotlin returns the failure) before the backend's connection changes; a
  silent address or another camera fails the connect. This is the shape Plan 5's
  `MultiviewMemberLink` wraps ("open at an address with identity check"). Tests:
  `LunaStationOpenTests` / `LunaStationOpenTest`.
- **LAN-first reconnect**: a backend remembers where each camera was last reached on a Wi-Fi or
  hotspot setup (`LunaStationHost`: network, address, the serial its control link proved;
  `stationHost(for:)` / `rememberStationHost(_:for:)` to hand one back from a journal). The next
  connect over that setup joins the phone, probes that address and opens the control link there
  with the serial check, without Bluetooth (`LunaStationReconnect` over the LAN-only open above).
  It falls back to the Bluetooth move (whose search tries the known address early) when the
  address is silent or answers as another camera. It never tries an address in
  `stationHostsInUse`, one on another network or one without a proven serial. Local Network
  denial, this phone failing to join the network (the move would strand the camera there),
  cancellation and (Android) a drop after the camera went live end the connect instead of moving
  the camera. The memory is
  per backend, in memory only, and is dropped by `forget`, a camera Wi-Fi connect and a return to
  the access point. Tests: `LunaStationReconnectTests` / `LunaStationReconnectTest`.
- **Nearby camera onto a network**: `LunaIntegration.target(_:onto:saved:)` (and
  `connect(_:onto:saved:)`) makes a Bluetooth sighting a connect target onto a
  `LunaStationNetwork` (the integration's twin of the app shell's `StationNetwork`). It is an Add
  setup: the password is kept, and the connected event carries the session and the record with
  the camera's own Wi-Fi and the setup, the setup preferred. A sighting that is not yet saved gets
  a record made from it, which `saveRecord` stores only once the camera starts to move (the
  backend reaches the network step), so an attempt that fails before then (not reachable, not
  approved) leaves no saved camera. A sighting that is already saved (`savedID`) needs its record
  as `saved`: the setup is added to it, so its camera Wi-Fi, its other setups and its serial stay
  (a Wi-Fi setup replaces its earlier Wi-Fi setup, a hotspot its hotspot, as Add setup does);
  without it the target is nil and `connect` fails at once, since a record made from the sighting
  would replace the saved one. Tests: `aNearbyCamera…` and `aSavedNearbyCameraKeepsItsRecordOnANetwork`
  in `LunaIntegrationTests` / `LunaIntegrationTest`.
- The Luna has no verified camera-driven network scan: the wizard keeps
  `cameraScansNetworks: false`, and nothing here scans networks through the camera.
- Bluetooth across backends: each iOS backend has its own `CBCentralManager`. A camera another
  backend sighted is still reachable: `LunaBluetooth.connect(id:)` falls back to
  `retrievePeripherals(withIdentifiers:)`, and peripheral identifiers are the same for every
  central in the app. Only the timeout copy differs (a backend that never heard the advert says
  the camera is missing rather than held). Android connects by address through the adapter
  (`getRemoteDevice`), independent of which backend scanned.

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
