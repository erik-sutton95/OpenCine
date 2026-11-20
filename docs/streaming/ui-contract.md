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
| Go live control | Over the monitor picture, top center, inside the picture | A stream key is saved for the selected service and "Go live button on the monitor" is on, or a stream is running |
| Status readout | Under the Go live control | Connecting, live or reconnecting |
| Notice | Under the Go live control | After a stream ends for a reason other than the operator's stop, or start fails |
| Warning | Under the status readout | While live and the phone is hot or its battery is low |

The Sharing tab appears when either feed sharing or live streaming is composed.

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
- `LiveStreamQuality`: `width`, `height`, `framesPerSecond`, `videoBitrateBps`.
- `LiveStreamPhase`: `idle`, `connecting`, `live`, `reconnecting(attempt)`, `ended(LiveStreamEnd)`.
- `LiveStreamEnd`: `stopped`, `refused(reason)`, `gaveUp`, `unreachable`, `background`,
  `microphoneDenied`.
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

Starting or stopping never sends a camera command.

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
