# OpenCineDJI

DJI camera integration for OpenCine apps (Swift). Protocol, wire and session code moved from
OpenPocketCine `Sources/OpenPocketViewCore` without behavior change (plan work package VENDOR-01):

- DUML framing, transport and notification assembly; datalink handshake admission; HEVC
  depacketizer; setting mailbox; command builders (`Commands`).
- Camera model, control, capability and status decode (`CameraModel`, `CameraControl`, `CamCap`,
  `CameraStatus`, `CamAudioStatus`); feed watchdog, link diagnosis and recovery ladders.
- BLE adverts, SoftAP, station join, multicam discovery and Wi-Fi scan.
- Media endpoints and live resume; AE/AWB lock, face-priority exposure, tracking box; native gimbal
  target stream, native program zoom, gimbal reach.
- DJI colour data: log curves, monitor LUT catalogue, clip colour profiles.

Depends only on `OpenCineCore`, `OpenCineMedia` and `OpenCineMotion` (same package; root
`Package.swift`). No UI and no app types. OpenPocketCine re-exports this module from
`OpenPocketViewCore`, so its app and Android JNI facade import nothing new.

```sh
swift build && swift test --filter OpenCineDJITests   # from the repository root
```

`DJICameraSessionAdapter` is OpenCineCore's `CameraSession` for common capture controls
over a `DJIControlPort` the app's DJI session implements (Pocket: `CameraSession+DJIControlPort`).
`DJICameraSessionAdapterPortTests` drive it with a fake port, without any app. The adapter reads
time from OpenCineCore's shared `MonotonicInstant.now()` (injectable), lists what the connected
body cannot do (`CameraModel` flags: aperture, focus, zoom) as unsupported, and leaves everything
else unknown. It publishes timecode (`timecode_info`; Nano: unsupported) and live audio levels
(`cam_audio_status_v2` in dBFS; every known body), each unknown until the camera reports
(`CameraStatus.audioMeters` is `nil` until then). `CameraModel.motion` is what a body declares to
OpenCineMotion (`MotionCapabilities.pocketGimbal` with camera-reported pose; `nil` without a gimbal),
and `layout(base:)` projects the snapshot and that motion for a monitor. DJI's official
Rec.709 look curves live in `DJILook`, not on the neutral `LiveColorScience`.

The additive `DJICaptureControlState` supplies actual decoded reports separately from pending
presentation pins. It enables shutter durations, exposure compensation, AF-S/AF-C and zoom,
with mirrored Kotlin ports. Shutter choices come from the camera's capability report and require
reported Manual exposure; a common duration request never switches exposure mode implicitly.
Zoom bounds follow the reported format and mode. ACK and legacy optimistic settlement never
manufacture an observation; an actual matching report can confirm a sent command before its ACK.
Measured iris is a read-only f-number. Auto/Starburst aperture strategy remains a typed DJI panel.
Older ports retain their original controls until they provide this optional state and writes.

## Apple transport (`OpenCineDJIApple`)

The iOS-only integration target owns Bluetooth discovery and link delivery, Wi-Fi joining,
local-network evidence, the Network.framework datalink and its receive/video assembly.
It depends directly on `OpenCineDJI`, `OpenCineMedia` and `OpenCineMotion`. It imports no UI,
app or neutral monitor runtime. Portable DJI gimbal move/zoom execution and Bluetooth peer
selection remain in `OpenCineDJI`; app views and composition stay outside the integration.

`DjiAppleTransportHost` supplies per-instance diagnostic delivery, permission copy and
local-network evidence callbacks. The app owns privacy redaction, journal storage, credentials,
Bonjour permission presentation, foreground policy and incident enrichment. Bluetooth and
datalink owners preserve their main-actor callback ordering; background assembly protects its
own value state. A queue with no pending item has an unknown age (`nil`), while known empty
counts and bytes are zero. Legacy incident schemas may map that age in their app adapter.

`DjiAppleDatalink.incidentIngress` supplies generation-fenced raw receive facts
before video admission, fault injection and assembly. The neutral Media snapshot
keeps these facts optional for legacy producers. Native owners collect fixed-size
counts and monotonic ages without per-packet logging; apps sample them on the
existing incident timeline. Local registration counts cover successfully
submitted app-presence frames, not peer confirmation. Retirement clears the
counter epoch before late callbacks can reach a replacement.

The package remains resolvable on other platforms through iOS source guards. The Pocket app
adopts these owners with configured aliases and host callbacks; its remaining camera-session
orchestration is a separate migration. Import-rule and callback/assembly tests live in
`Tests/OpenCineDJIAppleTests`. This is a local candidate: camera behavior is untested on hardware.

`DjiAppleControlExchange` owns the single Bluetooth frame drain, grouped reply requests,
held pairing replies and actual SET mailbox execution. The native endpoint distinguishes
queued sequence zero from a skipped write. SET sequence routing precedes same-opcode GET;
unsolicited Selfie Flip cannot consume either. Request cancellation and scheduled work carry
operation identity as well as the endpoint generation. Retirement completes only local work;
the app still owns transport close, native motion cleanup and session recovery.

Its host supplies one control context, typed effects and journal delivery. Actual camera
reports confirm common command receipts. The explicitly named `legacySettlement` projection
retains existing busy-state, mailbox and recovery behavior; presentation pins cannot confirm
a common receipt, and unobserved recording is not reported idle. Retry remains 300ms, settle
remains 2s, and coalescing retains 100ms ordinary/50ms pipelined-zoom cadence. Apple tests cross
the same interface using manual timing and a SIMULATED peer on the actual UDP queue.

`DjiAppleSessionHeartbeat` owns one connection's asynchronous first registration and
one-second wait after each tick. It sends BLE keepalive before the actual datalink's
registration/ACK, including during inactive scenes, covers and held picture. Existing
`CameraPathRecovery` checks actual packet freshness and eight-second reassociation grace
before any write. The host retains native picture/watchdog, gallery, incident journal
and motion policy through bounded synchronous maintenance effects; the owner resamples
host and transport facts before the unchanged two-second Selfie Flip fallback.

Each run, scheduled wake and endpoint replacement has an identity. Old or duplicate wakes
cannot write into a successor or cancel its deadline. Retirement stops only local work;
explicit transport disconnect remains with its actual owner and never sends stop-record.
Date-based transport observations and monotonic path grace retain their original clocks.
The real native endpoint and SIMULATED manual-clock peer use the same interface. This
Apple-specific ownership move changes no portable/Kotlin protocol or hardware admission.
Larger foreground and watchdog execution remain
separate increments; full Pocket session migration and physical qualification are unfinished.

`DjiApplePictureRecovery` owns one session's serialized repair task and retirement
generation, actual endpoint negotiation, genuine-picture deadline and held-cycle history.
`start` admits one operation; its `Attempt` can repair an endpoint or await picture after
the host's existing full rejoin. `claim` queues current media return behind that same
repair, including a nil-driver gap. Local cancellation sends no camera command and
preserves the existing per-session held-cycle history.

The native adapter supplies ordered preparation, one initial enable, bounded first-picture
inspection and a freshness predicate derived from actual source/presentation reports.
The integration never imports the neutral native runtime. Media retires picture intent
without canceling admitted negotiation; a genuine current-transport failure still reaches
session recovery. Driver/run replacement suppresses stale completion. Existing 100ms
polling, 16s picture deadline and FeedWatchdog held-cycle policy remain unchanged. Manual
timing tests exercise canceled waits that deliberately resume after a successor starts.
Current-driver preparation still precedes negotiation when that driver is closed; the
native negotiation's existing closed path sends nothing, and picture enable remains
refused. Injected transport observations are rechecked before held-history mutation or
completion effects. If an effect retires the attempt, its result is `superseded` and its
completion cannot release the successor. Authorized held history survives local retirement.
The app retains native watchdog actions, gimbal cleanup, full recovery backoff/credential
policy, journal and explicit owned-versus-borrowed teardown. This Apple-only workflow adds
no Kotlin scheduler or portable contract; physical camera qualification remains untested.

`DjiAppleConnectionRun` owns the finite Bluetooth/pair/AP-or-station/registration
workflow. It uses the existing exchange and heartbeat owners and preserves native
retry/settle/credential/identity rules. OS services are one per-instance transport
aggregate; saved credentials and native source preparation, endpoint attachment and
synchronous initial-enable policy are grouped host adapters. `DJIConnectionRoute`
(Kotlin `DjiConnectionRoute`) aliases Core's route kind; optional station credentials
are sampled after pairing, so a missing network stays unknown until that boundary.

Run identity fences awaits and synchronous effects. A retired factory attempt closes
only its unadopted endpoint; a reentrant observation cannot authorize closing one
handed to a successor. Registered/subscribed remains a synchronous host action before
the initial enable, independently of fresh-picture recovery. Retirement sends no
command and leaves explicit transport/motion teardown with the host. Borrowed or
unknown connection authority refuses before native preparation. Manual-clock tests
replay independent SIMULATED app-donor traces; physical qualification remains untested.
After current owned preparation, a replacement retires the old BLE drain and local
exchange state before GATT. Old held or late approval cannot qualify the new workflow;
reentrant preparation cannot retire a successor's request or held reply.
Unsupported USB/capture-device routes refuse before native preparation or Bluetooth
writes. Unknown network credentials on a supported station route still fail at the
original post-pairing sampling boundary.
Pocket retains storage namespaces, permissions, native picture/watchdog, error copy,
scan and full recovery budgets. Android keeps its existing owner and platform cadence;
no portable or Kotlin scheduler is added. Full Pocket P2 migration is unfinished.

## Android (`Android/dji`, `com.opencapture.opencine:dji`)

The Kotlin DJI layer, moved from the OpenPocketCine app without behavior change (SHELL-04): BLE
link and initialization, the Wi-Fi datalink driver, DUML command and status models
(`CameraCommands`, `CameraStatus`, `CameraModel`, `VideoFormat`, `CamFov`), gimbal programs and
the native program runner, connection and live-view policies (`LiveViewEnablePolicy`,
`SessionRecovery`), Multiview `StationJoin`, `ConnectionPhase`, and `DjiCameraSessionAdapter`
(OpenCineCore `CameraSession` over a `PocketControlPort`). Depends on `core`, `media`, `decoder` and `platform`; Android framework adapters stay outside portable policy.
The adapter mirrors the Swift one for SHELL-01: timecode and audio level support and values
(`CameraStatus.audioMetersReported` keeps "not reported" apart from silence across the facade),
`pocketGimbal` and `CameraModel.motion`, and `layout(base)` with the same capture descriptor rules.
`DjiControlSessionBinding` caches one control seam per native connection, retires it before a
replacement, and fences late close callbacks from the successor. Borrowed Multiview settings
come from the tile's actual decoded aggregate; editor pins remain in the borrowed presentation.

Wire bytes come through `DjiNative`, a JNI facade whose class name is part of the native symbols
(`Java_com_opencapture_opencine_dji_DjiNative_<name>`). The Swift side is the product
`OpenCineDJIAndroid` (`Sources/OpenCineDJIAndroid`: the `@_cdecl` exports, `#if os(Android)`, and
the Darwin-testable `DjiNativeWire` helpers over OpenCineDJI). `OpenCineJNISupport`
owns JNI string, buffer and method lookup helpers over the `OpenCineJNI` header shim;
integration and app facades use that one implementation.
An app adds the product to the target that builds its Swift Android library and the 30 exports
ship in that `.so`; `consumer-rules.pro` keeps the Kotlin class in minified apps. The app calls `DjiNative.load(<its library>)` once at startup and points `DjiLog.sink`
at its diagnostics. Swift and Kotlin `CamFov` share `Fixtures/camfov-vectors.tsv`.

The session itself is here too: `DjiCameraSession` (BLE to pairing to camera Wi-Fi to datalink to
live picture, recovery, operator commands, Multiview station join), with the Wi-Fi joining and saved
credential stores, feed incident models, capture value lists and gamepad actions it uses. What
stays with the app comes in through `DjiSessionHost`: operator preferences, the feed incident
recorder and reliability reporting, build identity, and the face detector (`FaceDetectorPort`; the
app keeps ML Kit). The app keeps all UI.

## Integration contract (SHELL-02)

`DJIIntegration` (Swift, over a `DJIConnectPort` the app's DJI connect pipeline implements in
step 7) and `DjiIntegration` (Kotlin `:dji`, over a `DjiConnectPort` that `DjiCameraSession`
implements) are DJI's Core `CameraIntegration`:

- Discovery is `.passive` only (Bluetooth adverts). Profiles: the verified bodies; those that list
  in Multiview add Wi-Fi and hotspot setups (`MulticamSupport.appears`).
- One connection at a time over camera Wi-Fi or a Wi-Fi or hotspot setup that moves the camera.
  Steps are the connect card's ("Connecting over Bluetooth", "Joining camera Wi-Fi" or "Moving the
  camera to <network>", "Opening the video link" or "Finding the camera", "Starting the
  picture"); the approval prompt is `approveOnCamera("Approve on the camera")`. A camera whose
  preferred or last setup moved it connects with `restoreAccessPoint`.
- Adding a setup (`ConnectTarget.addRoute`) hands the network and password to the pipeline
  (Kotlin: saved to the shared network store first).
- Failures keep the session's copy, typed (Kotlin `DjiFailures.classify` where the session catches
  a connect error, published as `PocketCameraSession.failureDetail` beside the unchanged
  `failure`); a failed moving setup offers Edit setup, Try again and the camera's own Wi-Fi.
- The record after a connect: the used route preferred, the joined camera network, the advertised
  model id (`extras["modelId"]`), the time. `forget` drops the camera's saved Wi-Fi only.
- Tests: `DJIIntegrationTests` / `DjiIntegrationTest` against fake ports, same method names.

## Neutral Android utility ownership (SHELL-04)

`:media` owns incident classification, recovery-effect values/logging, diagnostic redaction,
shutter-angle math and EV display/parse math. DJI retains its existing incident DTO JVM paths
and methods as compatibility adapters through private Media value projections; they keep the
same schema, enum wire strings and export shape. New consumers use the neutral Media values.
The DJI EV `0x10` wire offset and supported +/-3 EV range remain integration-owned.

`:platform` owns Android Keystore sealing and configured Wi-Fi credential storage. It imports
no integration, UI or app and adds no third-party packages. Existing DJI and app wrapper classes
supply the unchanged `openpocketcine.camera-wifi` preferences namespace and key alias, camera
`.ssid`/`.password` keys and trimmed `ssid:` index. The envelope remains Base64 IV, colon,
Base64 AES/GCM payload, 128-bit tag and no AAD; unreadable ciphertext stays unknown and legacy
plaintext migrates idempotently. Multiview network storage keeps its existing separate alias.

Media's redactor defaults to redacting all SSIDs. The compatibility wrappers supply the
existing safe-network policy so neither app's exported diagnostic behavior changes. Neutral
shutter observations return `null` for unknown shutter/rate, matching Swift Media; legacy
Android capture wrappers keep their existing 180-degree/24-fps display fallback until their
callers migrate explicitly.

## Session names and compatibility

Android apps compose `DjiCameraSession` with a `DjiSessionHost`. These preferred
integration-level names are source aliases of the existing JVM types
`PocketCameraSession` and `PocketSessionHost`. The same class, constructor,
private fields and runtime owner remain in use. Legacy callers and compiled
entry points remain compatible; retirement of the old names belongs to a later
minor release after all consumers migrate. JNI class/member names are unchanged.

## Native Apple media browse producer

`DjiAppleMediaService` owns playback entry retries, wire-ordered SD/trigger/internal
catalog queries, assembler collection, paged cursors and the finite live-return
loop. `DjiAppleMediaPort` supplies primitive IO, actual captured connection facts
and admission through the genuine picture-recovery owner. Thumbnail, transfer and
delete services remain absent until their real owners migrate.

Raw UDP reception captures a query/browse/source ingress ticket before actor
queueing. Endpoint replacement retires catalog admission while preserving the
same-session return authority, including a nil-driver recovery gap. Closing a
retired connection sends no return command. Fixed wire counters do not provide
remote packet correlation; the ticket fences locally queued input.

No-response catalog work throws unavailable; it never publishes a known-empty
catalog. An actual completed empty reply publishes known empty. Gallery-open
refusal and newest-page fallback after failed playback entry remain intact.

Swift and Kotlin connection records forward supplied optional services, preserving
legacy absent defaults. `DJICameraSessionID` and `DJIControlEpoch` alias the exact
Core identity types through the declared DJI dependency; the Apple target adds
no dependency or direct Core import.

The local Pocket adopter passes portable/strict/repository checks, both simulator
architecture builds, all 16 selected native recovery/cache/port methods, Android
native staging, full shared/consumer checks and JNI/package validation. Shared
manual-clock owner and mirrored registration scenarios pass. Physical camera
listing/gallery/live return remains untested. The browse producer is Apple-only;
Android retains its existing media owner. Full library/cache/player migration
and app pin moves remain separate work.

## Native Apple subject tracking

`DjiAppleSubjectTracking` owns one actual ActiveTrack workflow: request IDs, pending
operator-box acceptance, live/poll report handling, smoothing, polling and local
clear history. Its snapshot is committed before host notifications. The host
supplies the actual datalink/control-generation binding, its existing low-level
command admission and native face/focus presentation. No app or UI is imported.

The captured binding and generation retire stale acknowledgement/poll work. A
captured publication authority fences synchronous native preparation after
reentrant replacement. Local stop/reset sends no camera command. Existing DJI
wire/math policies and operator conditional CLEAR remain unchanged. Manual timing
can be injected without sleeping or creating a camera. This Apple-only source
candidate is uncompiled and unexecuted; Android keeps its current integration
owner, and physical camera tracking remains untested.

`DjiAppleCameraSettings` owns the actual camera-settings FIFO and coherent GET/SET
workflows. It consumes low-level native request IO and captured typed audio/glamour
facts, and emits typed native presentation outcomes. The host retains optimistic
pins, control notes, logging and real packet admission. The owner does not call a
host's old whole workflow, invent raw blobs or change shared command contracts.
Tracking publication also uses its original committed revision across callbacks;
a local clear during notification cannot send an outgoing SET afterward. All
paired source scenarios remain uncompiled/unexecuted and physical untested.

`DjiAppleTapFocus` is a source-only Apple candidate that owns the complete independent tap
request task. It sends the original untracked PREPARE before point ACK admission, then
uses the existing native request primitive for point, hint and commit with 800 ms deadlines.
The actual endpoint/control generation and local task identity fence every continuation
and synchronous native/diagnostic callback. Point refusal stops; hint refusal still commits.
The owner sends no command on retirement and never joins the settings FIFO. Native focus
presentation and diagnostic copy remain explicit host policy. Portable command builders
and Kotlin behavior are unchanged; platform and physical qualification remain untested.

### Apple first-picture format and zoom-color ownership candidate

A source-only DJIApple candidate owns the complete first-picture format kick/restore task,
its original50ms pin wait and0.8s settle floors, actual binding/task admission and local reset.
The host supplies only the existing single-format pin/shutter-rematch primitive and live-view
request primitive. No nil transport is converted into readiness.

The same candidate owns color-hop deadlines, camera-status D-Log confirmation, captured
pending zoom/stage accounting, actual mailbox command descriptors/options and parked-wide
restoration. Its flush sends the shared slider recipe directly; it never invokes the app's
old whole slider workflow. Native HUD/pins/logging/ISO preference and gesture presentation
remain host policy. Captured endpoint/control ownership fences callbacks and pending writes;
committed snapshot revisions fence synchronous publication reentry. Android's existing
integration remains unchanged. Candidate cases and actual native host fixtures have not been
compiled or executed; physical behavior is untested.

## Native Apple gimbal control

`DjiAppleGimbalControl` owns the Pocket gimbal over the native datalink: the stick stream
(ramp, invert, rest), mode and speed SETs with their `CameraValuePin` readback pins, the
`GimbalStickMapping` pose (Flip, TT180, body face), the limit watch, Double-tap Level
(`WorldLevelSnap`), head-tracking target tokens and programmed moves (countdown, native
take, pause, cancel). It reads session facts through `DjiAppleGimbalHost` when it decides
and writes the observable gimbal state the host publishes; picture flip, zoom retirement
and the journal stay host policy. `DjiAppleGimbalLink` is the datalink surface, so the
owner tests run on manual clocks with a fake link. Cancellation re-checks the caller's
`ifCurrent` after every published write. `GimbalRampFilter` moved into OpenCineDJI next to
its Kotlin mirror in `Android/dji`. `CameraValuePin` is OpenCineCore's and the world level
math OpenCineMotion's (Kotlin: `core` and `motion`); OpenCineDJI keeps the `0x04/0x05`
attitude decode, `LevelReading.ingest(_:now:)` over a push and the `0x04/0x14` snap frame
(`WorldLevelSnap.plan`).
`GimbalMoveEngine`, `GimbalOverlayMotion` and the program zoom demand are shared in
OpenCineMotion; `GimbalMoveEngine()` binds them to `.pocketGimbal` and
`NativeProgramZoomCommand.frame` encodes the demand. On Android the waypoint, program, curve,
path math and overlay projection are core `motion`'s; `Android/dji` keeps the Kotlin
`GimbalMoveEngine`, the zoom path and native zoom demand, and binds the Pocket reach
(`GimbalWaypoint.PAN_MIN_DEG` and the rest, `unwrapYaw(raw)`, `from`, `clamped()`) and the 84°
overlay field of view (`GimbalWaypointOverlay.project(waypoint, live, aspect)`). Physical
behavior is untested.
