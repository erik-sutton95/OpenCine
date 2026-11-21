# Live stream UI contract (SwiftUI and Compose)

The one shared live stream surface, written down so the SwiftUI views (`MonitorUI`) and their
Compose twins (`monitor-ui`) show the same screens, states, copy and identifiers. Values and
actions only: the views never import the engine, a camera integration or an app. App differences
arrive as host values (keychain service or keystore alias, the connection route, the source
format), never as a brand branch.

Spec: [the RTMPS design](../superpowers/specs/2026-11-05-rtmps-streaming-design.md).
Swift source of truth for every string below: `Sources/MonitorPresentation/LiveStreamPresentation.swift`
(`LiveStreamCopy`). When a string changes there, change it here and in Kotlin in the same change.

## Surfaces

| Surface | Where | Shown when |
|---|---|---|
| Live stream card | Settings, Sharing tab, after the feed sharing rows | The app composes streaming (always, in the three camera apps) |
| Go live control | Top right, hanging under the status row (the timecode block) at its trailing edge (`LiveStreamOverlayPlacement.anchor`); with the status row off, the same top trailing corner. Hidden, still mounted, while the zoom ruler is open | A stream key is saved for the selected service and "Go live button on the monitor" is on, or a stream is running |
| Status readout | Under the Go live control | Connecting, live or reconnecting |
| Notice | Under the Go live control | After a stream ends for a reason other than the operator's stop, or start fails |
| Warning | Under the status readout | While live and the phone is hot or its battery is low |
| Live pill | App root, top center, inside the safe area | A stream runs and no monitor overlay is on screen (the monitor closed after the camera was lost, or a Multiview stage opened) |

The Sharing tab appears when either feed sharing or live streaming is composed.

## Host slots (how an app composes the surfaces)

The shared screens own placement; an app only hands over its coordinator.

| Surface | SwiftUI | Compose |
|---|---|---|
| Live stream card | `MonitorOperatorSettingsConfiguration.withLiveStream(coordinator)`: the shared settings screen renders the card as the Sharing tab's `liveStream` row. `nil` (or not calling it) leaves the row out | The shared operator setup or settings screen takes the same optional slot; an app passes its coordinator or nothing |
| Monitor controls | `LiveStreamMonitorOverlay(coordinator:)`, a plain view. The shared live screen places it from `MonitorOperatorLiveScreen.liveStream`; an app that draws its own picture (OpenZCine) places the same view at `LiveStreamOverlayPlacement.anchor` and passes `hidden` while its zoom ruler is open | A plain composable over the coordinator's state, with no dependency on the monitor feed host's scope, so an app that draws its own picture can place it |
| Lifecycle and Live pill | `.liveStreamLifecycle(coordinator)` once at the app root: background end, heat and battery warnings, and the Live pill | The same once at the app root |

The monitor overlay reports when it is on screen and off screen (SwiftUI: on appear and on
disappear; Compose: entering and leaving composition). The coordinator counts those; the Live
pill shows only while a stream runs and the count is zero, so the operator can always see and
stop a running stream.

## Microphone permission

The stream asks for the microphone only after the operator confirms Go live, and only through
the app's own permission path: the host value `microphoneAccess` (SwiftUI `LiveStreamHost`,
an async closure that returns whether the microphone may be used). Shared views and the overlay
never raise the system prompt themselves. An app with no gate of its own passes
`LiveStreamHost.systemMicrophoneAccess` (SwiftUI); on Android the app routes it through its
permission gate (activity result). A `false` answer ends the start with `microphoneDenied`.

## Values (portable, `MonitorPresentation`; Kotlin same names in `monitor-ui`)

- `LiveStreamServiceOption`: `id`, `name`, `keyHint`, `needsServer`, `acceptsPlainServer`,
  `vertical`. Built by the composition layer from the engine's `StreamServicePreset.all` plus
  `.custom`, in that order: Twitch, YouTube, Facebook, Instagram, Custom server.
- `LiveStreamKeyState`: `absent`, `saved`, `unavailable` (the keychain or keystore is locked:
  never treat as absent, never offer Save over it).
- `LiveStreamEligibility`: `allowed`, `cameraWiFi`, `noCamera`. From the host's connection route:
  USB-C cable, HDMI capture card, shared Wi-Fi network and the device's own hotspot are
  `allowed`; the camera's own Wi-Fi is `cameraWiFi`; no camera or an unknown route is `noCamera`.
  An app that states its route as Core's `RouteKind` maps it with the engine's
  `StreamConnectionRoute(_ kind: RouteKind)` (camera access point is the one blocked route).
- `LiveStreamMonitorState`: the control, service name, quality, `encrypted`, status, end and warning.
- `LiveStreamQuality`: `width`, `height`, `framesPerSecond`, `videoBitrateBps`, `kind`
  (`LiveStreamQualityKind`: `source`, `upscaled`, `camera`).
- `LiveStreamQualityOption`: `id`, `title`, `detail`, `unavailableReason` (an option with a reason is
  listed but cannot be chosen). The settings state carries `qualityOptions` and `selectedQualityID`
  (Kotlin `selectedQualityId`); the ids are the engine's `StreamQualityChoice` raw values
  (`cameraFeed`, `upscaled1080p`, `camera1080p`).
- `LiveStreamCameraStatus`: `starting`, `live`, `recovering`, `lost`, `notResponding` (while the
  stream carries the camera's own picture); `LiveStreamNetworkChoice`: `id`, `name`. The monitor
  state carries `cameraStatus` and `networkChoices`.
- `LiveStreamPhase`: `idle`, `connecting`, `live`, `reconnecting(attempt)`, `ended(LiveStreamEnd)`.
- `LiveStreamEnd`: `stopped`, `refused(reason)`, `gaveUp`, `unreachable`, `background`,
  `microphoneDenied`, `cameraDidNotStart`, `cameraNotResponding`.
- `LiveStreamHealth`: `good`, `congested`, `offline`.
- `LiveStreamStatusState`: `phase`, `elapsedSeconds`, `sentBitrateBps`, `droppedGroups`, `health`.
- `LiveStreamWarning`: `hot`, `lowBattery`.

## Live stream card (settings)

Card title: `Live stream`. Rows in order:

| Row | Control | Identifier | Notes |
|---|---|---|---|
| Service | Picker of the service names | `monitor.livestream.service` | Below it, the selected service's key hint (`monitor.livestream.keyHint`) |
| Server | Text field, placeholder `rtmps://` (Custom: `rtmps:// or rtmp://`) | `monitor.livestream.server` | Only when `needsServer`. Stored with the key in secure storage |
| Plain warning | Warning note, accent or warning color | `monitor.livestream.plainWarning` | Only when `acceptsPlainServer` and the server starts with `rtmp://` (any case) |
| Server problem | Note | `monitor.livestream.serverProblem` | After a failed Save, the parse error copy |
| Stream key | absent: masked field `Paste stream key`, a Paste button and a `Save` pill | `monitor.livestream.key`, `monitor.livestream.key.paste`, `monitor.livestream.key.save` | The key is never displayed, not even masked length |
| | saved: value `Saved` and a `Remove` pill | `monitor.livestream.key.saved`, `monitor.livestream.key.remove` | Remove asks once (below) |
| | unavailable: note | `monitor.livestream.key.unavailable` | No Save, no Remove |
| Quality | Value | `monitor.livestream.quality` | Vertical services add the vertical note (`monitor.livestream.verticalNote`) |
| | With two or more choices: a picker of the choice titles, then the value, then the selected choice's detail or unavailable reason as a note | `monitor.livestream.qualityChoice`, `monitor.livestream.qualityDetail` | Locked while a stream runs |
| Go live button on the monitor | Switch, default on | `monitor.livestream.showOnMonitor` | |
| Eligibility | Note, only when not `allowed` | `monitor.livestream.eligibility` | The long reason |
| Locked | Note, only while connecting, live or reconnecting | `monitor.livestream.lockedWhileLive` | Service, server and key are disabled while a stream runs |

The key hint under the service picker is the preset's own sentence (engine content); the Custom
hint also says where TikTok LIVE shows its server URL and key.

Card copy: row titles `Service`, `Server`, `Stream key`, `Quality`, `Go live button on the monitor`;
saved key value `Saved`; locked keychain note `Unlock this phone to read the saved key.`; locked
note `Settings are locked while a stream runs.`; buttons `Paste`, `Save`, `Remove`. Plain warning:
`Not encrypted. rtmp:// sends the picture and the stream key in the clear, so anyone on the network path can read the key. Use rtmps:// when the service offers it.`
The server field is locked once a key is saved (remove the key to change it).

Remove confirmation: title `Remove the stream key?`, message
`The key for <service> is deleted from this phone. You can paste it again later.`, buttons
`Remove` (destructive) and `Cancel`.

## Go live control (monitor)

One control, identifier `monitor.livestream.goLive`. Minimum touch target 44 points (48 dp).

| State | Title | Enabled | Caption | Accessibility label | Accessibility hint | Tap |
|---|---|---|---|---|---|---|
| idle, allowed | `Go live` | yes | none | `Go live` | `Starts streaming to <service>` | start confirmation |
| idle, blocked | `Go live` | no | short reason | `Go live, unavailable` | long reason | none |
| connecting | `Connecting` | yes | none | `Connecting to <service>` | `Ends the stream` | stop confirmation |
| live | `LIVE <elapsed>` | yes | none | `Live for <spoken elapsed>` | `Ends the stream` | stop confirmation |
| reconnecting | `Reconnecting` | yes | none | `Reconnecting, attempt <n>` | `Ends the stream` | stop confirmation |

Start confirmation: title `Go live on <service>?`, message
`<quality>. The camera picture goes out with the monitor LUT; assists and controls do not. Camera recording is separate.`
When the server is plain `rtmp://`, a second paragraph: `Not encrypted: the stream and its key travel in the clear.`
Buttons `Go live` and `Cancel`.

Stop confirmation: title `End the stream?`, message
`Viewers see the stream end. Camera recording is not affected.`, buttons `End stream`
(destructive) and `Keep streaming` (cancel).

With the `1080p from camera` choice the start message is
`<quality>. The camera's own picture goes out in standard color, without the monitor LUT, with the camera's sound. Camera recording is separate.`
When two or more shared networks are saved, the confirmation offers one button per network instead
of `Go live`: `Go live over <network>`, the phone's hotspot first.

Starting or stopping never sends a camera command, except with `1080p from camera`: the camera is
told to publish its own stream on start, and to end it on stop, on every failure and when the app
leaves the screen.

## Camera stream status (`1080p from camera`)

Under the status readout, identifier `monitor.livestream.cameraStatus`, while the stream carries the
camera's own picture. `Retry` (`monitor.livestream.cameraRetry`) asks the camera to start again; the
outgoing stream stays up on the slate meanwhile, and ending it stays the operator's action.

| Status | Copy | Retry |
|---|---|---|
| `starting` | `Starting the camera's stream.` | |
| `live` | `1080p from camera. Assists, scopes and camera controls are off in this mode.` | |
| `recovering` | `The camera's stream stopped. Trying again.` | |
| `lost` | `The camera's stream did not come back.` | yes |
| `notResponding` | `The camera is not responding. Hold its power button about 10 seconds to restart it.` | yes |

## Live pill (app root)

Identifier `monitor.livestream.pill` for the status (one accessibility element) and
`monitor.livestream.pill.stop` for the Stop button. Minimum touch target 44 points (48 dp) for
Stop. Value `LiveStreamPillState(phase, serviceName, elapsedSeconds)`.

| Phase | Title | Dot | Accessibility label |
|---|---|---|---|
| connecting | `Connecting` | warning color | `Connecting to <service>` |
| live | `LIVE <elapsed>` | recording red | `Live on <service> for <spoken elapsed>` |
| reconnecting | `Reconnecting` | warning color | `Reconnecting to <service>, attempt <n>` |

Stop button: title `Stop`, accessibility label `Stop the stream to <service>`. It opens the same
stop confirmation as the monitor control (`End the stream?`, `End stream`, `Keep streaming`).
The pill has no start action and never shows when idle or ended; notices stay on the monitor.

## Status readout

Identifier `monitor.livestream.status`; one accessibility element with the combined label.

| Part | Copy | Example |
|---|---|---|
| Elapsed | `m:ss` under an hour, `h:mm:ss` from an hour | `12:34`, `1:02:03` |
| Sent bitrate | one decimal in Mbps from 1 Mbps, whole kbps below | `3.1 Mbps`, `850 kbps` |
| Dropped | `Dropped <n>` (whole video groups dropped by the send queue) | `Dropped 0` |
| Health | `Good`, `Slow network`, `Offline` | |

Combined accessibility label:
`Streaming for <spoken elapsed>. Sending <bitrate spoken>. <n> dropped. Connection <good|slow|offline>.`
Spoken elapsed: `12 minutes 34 seconds`, `1 hour 2 minutes 3 seconds` (singular for 1).
Spoken bitrate: `3.1 megabits per second`, `850 kilobits per second`.

## Notices

Identifier `monitor.livestream.notice`, dismiss button `Dismiss` (`monitor.livestream.notice.dismiss`).

| End | Copy | Extra action |
|---|---|---|
| `refused(reason)` | `The service refused the stream: <reason>. Check the stream key and server.` | |
| `gaveUp` | `The stream ended: the network did not come back within 2 minutes.` | |
| `unreachable` | `Could not reach the streaming server. Check this phone's internet connection, then go live again.` | |
| `background` | `The stream ended when the app left the screen.` | `Restart stream` (`monitor.livestream.restart`), starts at once with the same settings, no confirmation |
| `microphoneDenied` | `Allow microphone access in Settings to go live.` | |
| `cameraDidNotStart` | `The camera did not start its stream. Try again, or choose Camera feed in the live stream settings.` | |
| `cameraNotResponding` | `The camera stopped responding. Hold its power button about 10 seconds to restart it, then go live again.` | |
| `stopped` | no notice | |

## Warnings (while live)

Identifier `monitor.livestream.warning`. The stream never stops for these.

| Warning | Copy |
|---|---|
| `hot` | `The phone is hot. The stream continues; give it air or shade.` |
| `lowBattery` | `Battery is low. The stream continues until the phone stops it.` |

## Eligibility copy

| Value | Short (control caption) | Long (settings note, control hint) |
|---|---|---|
| `cameraWiFi` | `Camera Wi-Fi has no internet` | `This phone is on the camera's own Wi-Fi, which has no internet. To go live, connect the camera over a shared Wi-Fi network, this phone's hotspot or a cable.` |
| `noCamera` | `No camera` | `Connect a camera to go live.` |

## Quality copy

`<height>p, <fps> fps, <bitrate>`; fps is a whole number unless fractional (`29.97`); bitrate as in
the status readout. Example: `720p, 30 fps, 3 Mbps`. A vertical output names its short side:
`720p vertical, 30 fps, 3 Mbps`. Before a camera is connected: `Set from the camera when you go live.`

Quality choices, offered for the connected source (the remembered choice applies only while it is
offered; otherwise the stream uses Camera feed):

| Choice id | Title | Detail | Offered when |
|---|---|---|---|
| `cameraFeed` | `Camera feed` | none | always |
| `upscaled1080p` | `1080p upscaled` | `The camera feed scaled up to 1080p, with your LUT.` | the source's short side is below 1080 |
| `camera1080p` | `1080p from camera` | `Sharper picture, encoded by the camera, standard color, no LUT.` | the host declares that the selected camera can publish its own stream; listed unavailable, with `Save a shared network in the camera's Wi-Fi setup to use this.`, while no shared network is saved |

An upscaled output always says so in its line: `1080p upscaled, 30 fps, 6 Mbps` (vertical:
`1080p vertical upscaled, ...`); the start confirmation uses the same line. The camera's own
picture reads `1080p from camera, 30 fps, 6 Mbps`.

Vertical note: `This service takes a vertical picture: the stream is a 9:16 center crop of the camera picture, about <w> pixels wide from a <h>p feed before scaling.`
(`<w>` is the source height times 9 / 16, rounded down; `405` from 720p.)

## Server and key problem copy

| Engine error | Copy |
|---|---|
| `notRTMPS`, preset | `Use the rtmps:// address the service gave you.` |
| `notRTMPS`, Custom | `Use an rtmps:// or rtmp:// address.` |
| `invalidServerURL` | `The address needs a host and a path, like rtmps://live.example.com/app.` |
| `emptyKey` | `Paste the stream key.` |
| `keyLooksLikeURL` | `That looks like an address, not a key. Put the address in Server and the key here.` |

## Not in this contract

The program strip, cuts and timecode grades (part 4) and the cable route for more cameras (part 5).
