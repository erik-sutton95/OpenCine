# RTMPS live streaming: design

Status: draft for owner review, 2026-11-05.
Scope: project 1 of 3. Project 2 is the OpenCine desktop dock with its shared virtual webcam on
Mac. Project 3 is Windows and Linux. Each gets its own design. This one must not block them and
must not depend on them.

Marking: **[Owner]** was decided by the owner. **[Call]** is the author's call, open to correction.
Unmarked text describes the existing code.

## Intent

Someone running OpenPocketCine, OpenInstaCine or OpenZCine, and later OpenCine on desktop, can go
live to Twitch, YouTube, Facebook, Instagram or any RTMPS server directly from the app, without
OBS. With several cameras connected they can cut between angles mid-stream like a mini switcher,
and cuts land on matching moments because the feeds are aligned by timecode.

OBS remains the tool for anything richer. It gets each camera as its own video input in project 2.

## Goals

- **[Owner]** RTMPS output on iOS, Android and desktop. Desktop arrives with projects 2 and 3; this
  project builds it so desktop only adds a platform shell.
- **[Owner]** Service support for Facebook, Instagram, YouTube and Twitch, by stream key in the first
  release, plus any custom RTMPS server.
- **[Owner]** One stream at a time, carrying the main selected camera. The operator can switch to
  another angle mid-stream without the stream dropping.
- **[Owner]** Angles are aligned using each camera's timecode, so a cut does not jump in time.
- **[Owner]** Streaming needs a route to the internet. Cameras connect by USB-C (including HDMI
  through a UVC capture card) or by Wi-Fi with internet access.

## Non-goals for the first release

- **[Owner]** Signing in to service accounts from the app. Stream keys only.
- **[Call]** Fades, picture-in-picture, titles, graphics, scenes or several simultaneous destinations.
- **[Call]** Plain unencrypted `rtmp://`. Custom servers must be `rtmps://`.
- **[Call]** Recording the stream locally. Cameras already record their own footage.
- **[Call]** Jam sync, genlock or any automatic camera change. Clocks change only through the operator's
  **Line up cameras** step below.

## Anti-goals

- Claiming sync that is not real. Core already has this rule: clock-derived timecode "never claims
  sync" (`docs/core/README.md`). A cut that is only approximately aligned must say so.
- A stream failure that disturbs camera control, the monitor or recording. Streaming is a passenger.
- A stream key appearing in a log, crash report, problem report or screenshot-visible field.
- Per-brand or per-app streaming code. Every surface is one shared component, in step across
  SwiftUI and Compose, with app differences as host values.

## What exists today

| Need | Today | Consequence |
| --- | --- | --- |
| RTMP sender | None in any repository | New |
| Live H.264 encoder | Apple: `WatcherRelayEncoder` encodes live buffers, HEVC only. Android: no live encoder; `MediaCodec` encoding appears only for review clips | Apple adapts the pattern for H.264. Android is new |
| Live picture size | Pocket and Nano 720p, Luna 720p at 25 fps, Nikon live view JPEG at most 1024x768, multicam polled up to about 24 fps | Wireless feeds are below the 1080p default; see Quality |
| Live audio capture | None found in the monitor runtime paths. Core has audio level meters only | New on both platforms |
| Camera audio over Wi-Fi | Not found in the app's live paths; to confirm per camera | Audio starts as device mic or capture card audio |
| UVC input | Apple: `OpenCineApple/UVCVideoSource`, iPad only per its own copy. Android: `UvcCaptureSource` in the OpenZCine app, not shared. Pocket and Insta have no capture route; their settings say "not in this build" | Milestone 7 lifts it to shared code and adds it to Pocket and Insta |
| Secure storage | `WatcherRelayKeychain`, `FrameioHost`, `LunaSecureStore`; Android `KeystoreSeal` | Reuse |
| Redaction | `PrivacyRedactor` in the app shell | Extend for keys and ingest URLs |
| Several cameras in one app | OpenZCine and OpenPocketCine have a multicam stage. OpenInstaCine has none | Insta streams a single camera in the first release |
| Connection modes | Z has camera access point, phone hotspot, Wi-Fi network, USB-C and HDMI capture. Pocket and Luna have station modes | Each app states its connection mode as a host value |

## Behavior

### Setup

Each app has one **Live stream** settings page, the same shared component everywhere.

- **Service:** Twitch, YouTube, Facebook, Instagram or Custom. A preset fills in the server
  address and output defaults. Custom and Instagram ask for the server address too, because
  Instagram issues the address together with the key.
- **Stream key:** masked, pasted, stored in secure storage per service, and removable. Each preset
  shows one line on where to find the key in that service.
- **Quality [Owner]:** the stream matches the source and never pretends to more. Wireless feeds
  default to 720p; 1080p is offered only when a connected source really is 1080p, such as HDMI capture.
  **[Call]** With several cameras, the output is set at go-live from the best connected source and stays
  fixed; lesser sources are scaled to fit, keeping their shape (Nikon's 4:3 live view gets side bars).
  Frame rate follows the main selected camera at go-live. About 3 Mbps at 720p and 6 Mbps at 1080p, H.264
  with a 2 second keyframe interval, AAC-LC stereo at 48 kHz and 160 kbps. Each preset caps the bitrate at
  what that service accepts.
- **Audio source [Call]:** device microphone or capture card audio when the OS offers it. One source
  stays on through every cut.
- **Instagram framing [Call]:** Instagram expects a vertical picture, so its preset outputs a 9:16
  center crop with a visible framing guide before going live. From a 720p feed that is only about
  405 pixels wide before scaling, and the setup page says so. Other presets are 16:9. The other
  presets keep the source framing, letterboxed if the source is not 16:9.

Current service addresses and requirements must be confirmed against each service's own docs when
the presets are built, and they live in one data table so a change needs no code change elsewhere.

### Eligibility

**[Owner]** Streaming is limited to USB-C (including HDMI capture) or Wi-Fi with a route outside.
**[Call]** That means allowed: USB-C, HDMI capture, a shared Wi-Fi network and the device's own
hotspot. Blocked: connecting through the camera's own Wi-Fi network, assumed to have no internet. The control stays visible, is disabled and says why and
what to change. If internet is unreachable on an allowed connection, starting fails with a clear
message. Eligibility is a capability value from the host, never a brand check.

### Going live

- A **Go live** control sits with the monitor controls. Starting takes one confirmation showing the
  service and quality. Stopping takes one confirmation.
- While live, a status readout shows elapsed time, sent bitrate, dropped frames and connection health.
- **[Call] What goes out:** the clean camera picture, including the monitor LUT when one is on, but
  never assists such as peaking or false color, and never app controls.

### Switching (a program strip)

- **[Owner]** The stream carries the main selected camera. **[Call]** A strip of connected cameras
  appears only while more than one camera is available. A tap cuts to that camera.
- **[Call]** Hard cut only, on the next output frame. The output keeps one fixed resolution, frame
  rate and encoder session throughout; each source is scaled and its frames repeated or dropped to
  match. A keyframe is forced at the cut so viewers joining get a clean picture quickly.
- **[Call]** Available angles: on a phone, the cameras that app can already run together (Z and
  Pocket multicam stages). On desktop, every connected camera regardless of brand, since the dock
  hosts them all. Insta shows no strip.
- **[Call]** A preview of the outgoing picture is the current monitor. The operator sees live camera
  tiles, not the delayed stream.

### Timecode alignment

**[Owner]** Feeds are aligned by timecode. What cameras give us differs, and the design respects it:

| Source | What the code has | Alignment grade |
| --- | --- | --- |
| Nikon Z live view over PTP | Frame-counting timecode in every live-view frame header, when the body's timecode is on | Frame accurate, if the bodies' timecode shares a base |
| DJI Pocket | `timecode_info` as HH:MM:SS:FF, carried in camera status messages | Approximate until a hardware test shows how closely status follows frames |
| Insta360 Luna | Whole seconds only, clock derived, pinned by frame arrival; frames land 90 to 200 ms after their camera stamp | Approximate at best |
| HDMI through UVC capture | No timecode reaches the app through the UVC path | None, unless the same camera also reports it over a control link |

How it works:

1. Each source reports `(timecode, frame rate, arrival instant)` for a frame or status update through
   one neutral contract. Timecode is converted to a time position at that source's rate, honoring
   drop-frame and fractional rates where the camera states them.
2. For each source, the aligner tracks a smoothed offset between timecode position and local arrival.
3. **Comparable check:** a source joins alignment only if its timecode is advancing and lands within
   a tolerance of the other sources. Record-run timecode on an idle camera is frozen, and two cameras
   started on different bases will disagree by far more than any network delay. Both drop out rather
   than producing a wrong alignment.
4. Each aligned source's frames are delayed in a small bounded buffer so that the same timecode is
   available from all of them at the same output moment. The slowest source sets the delay.
5. **[Call]** The buffer is capped at 500 ms. A source needing more is treated as unaligned. Memory is
   bounded and frames are dropped oldest first; the buffer may not stall the monitor or camera control.
6. A cut selects the buffered frame matching the output timecode from the new source. If the source is
   unaligned, the cut takes its newest frame.
7. **[Call]** Audio from the chosen source is delayed by the same amount so it stays with the picture.
   Each camera also gets a manual trim in frames, for fine-tuning and for sources with no timecode.

**[Call]** Each camera in the strip shows its grade: `TC locked`, `TC approx`, or `Not aligned`, each
with an accessible label. The app cannot prove from values alone that cameras share a base (two bodies
set by a 1 second clock can agree within tolerance and still be frames apart), so passing the comparable
check earns only `TC approx`. `TC locked` also requires frame-precision, camera-reported timecode and the
operator stating, in the strip, that these cameras share a timecode source. Clock-derived timecode can
never show it. The wording avoids "sync" and "genlock", per the existing multicam rule.

Alignment applies to the RTMPS program only. The project 2 webcam inputs are independent, since OBS
owns switching there. Whether they should offer the same delay is a project 2 question.

**[Owner] Line up cameras:** before a multi-camera stream, the operator may confirm a one-tap step that
sets each camera's clock to the same time, where the integration can (Nikon and Luna already have clock
setting code; Pocket is to be checked). The step states what it changes, because a camera's clock also
reaches its footage metadata. Nikon's existing setting is only good to about 1 second, so **[Call]** the
per-camera manual trim is the expected finish, not a rare fallback. The step never runs automatically.

**Open risk to test first:** alignment only helps if a camera's timecode follows its clock or otherwise
shares a base. The first plan milestone measures this on real hardware. **[Owner]** The test set is one
of each brand, so cross-brand pairings can be measured and same-brand pairings cannot. **[Call]** Same-brand
pairings (Z multicam, Pocket multicam) therefore ship no better than `TC approx` until someone tests them
with two bodies, and switching itself does not depend on the result.

### When things go wrong

- **[Call] Selected camera drops:** hold the last frame for 2 seconds, then show a neutral slate.
  The stream and audio stay up, so the operator can cut to another camera or wait for reconnection.
- **[Call] Network drops:** retry with backoff for up to 2 minutes while showing it clearly. Output
  does not queue while offline. A refused key or server error stops immediately with a plain reason.
- **[Call] Slow network:** a bounded send queue. Lower the encoder bitrate within the preset's range,
  then drop whole video groups before audio. Latency may not grow without limit.
- **[Call] Thermal or low battery:** warn, never stop on our own, except where the OS forces it.
- **[Call] Backgrounding:** streaming is foreground only in the first release, identically on both
  platforms. Leaving the app ends the stream once the short OS grace is over. On return the app says so
  and offers one tap to restart with the same settings. This needs no background modes, and no camera
  link or frame production without a view. The screen stays awake while live.
- Starting or stopping a stream never sends a camera command. Camera recording is a separate action.

## Structure

**[Call]** Fits the boundaries in `AGENTS.md`, modeled on Gyro: one portable engine in Swift, used on
Android over JNI, so nothing is written twice, and thin platform shells.

- **`OpenCineStreaming`** (Swift, Foundation and Core only; no manufacturer or app name; service names
  are preset content). Pure logic over bytes and values: RTMP handshake and chunking, AMF0, FLV packaging
  for H.264 and AAC, the publish state machine, reconnect and congestion policy on a manual clock,
  service presets, program switching and the timecode aligner.
- **`OpenCineStreamingApple`**: TLS socket on Network.framework, H.264 on VideoToolbox, AAC on
  AudioToolbox, microphone and capture audio, keychain storage.
- **`OpenCineStreamingAndroid`** (JNI facade, as `OpenCineGyroAndroid`) and Android **`:streaming`**
  (Kotlin facade with stable JNI names): `SSLSocket`, `MediaCodec` H.264 and AAC, `AudioRecord`,
  Keystore storage.
- **Picture contract:** a neutral source of clean, timestamped frames, implemented for the Apple and
  Android native runtimes. The runtimes stay below UI and app composition. Android UVC moves from
  OpenZCine to shared code for this.
- **Shared UI** in `MonitorUI` and `monitor-ui` with composition in the app shell: settings page, Go
  live control, status readout, program strip. Values and actions only.
- **Integrations** only report timecode through the existing observations and frame metadata. The
  neutral contract takes per-frame timecode where it exists (Nikon).
- **Apps** add host values: keychain service, permission strings and connection eligibility.
- **[Call] Multicam picture sources:** the frames the program strip needs live in the apps today (Z
  `MulticamCoordinator` and `MulticamPicture`, Pocket `MultiviewSession`). They are not moved first.
  Each app implements the neutral picture contract as a thin adapter over its stage, like a camera
  joining through `GyroCameraAdapter`. The contract, switching and aligner stay shared, and no app
  holds streaming logic.

No third-party package is added. This keeps the repo rule, and keeps RTMP in code we own and can port
to Windows and Linux in project 3, where the portable engine is reused and only a new shell is written.

## Testing

Behavior tests at boundaries, per `AGENTS.md`:

- **Golden bytes:** handshake, chunking, AMF and FLV output against recorded bytes from a reference
  sender, in shared fixtures used by Swift and Kotlin.
- **Manual clock scenarios:** reconnect, congestion, feed loss, and the aligner across frozen timecode,
  disagreeing bases, drop-frame and mixed rates, seconds-only sources and the delay cap.
- **Key safety:** redaction tests proving a key never reaches logs or reports.
- **End to end:** a local TLS RTMP receiver in the test harness, labeled SIMULATED, with the received
  stream checked for codec, resolution, frame rate, timestamps that never go backwards across cuts, and
  uninterrupted audio.
- **Hardware pass** before any external build, using a live hands-on checklist page: each app on iOS and
  Android, real stream to all four services, each allowed connection that app has, blocked camera Wi-Fi,
  a long soak for heat and drift, and cross-brand cut accuracy checked by filming a shared clock on the
  available bodies (one of each brand).

## Delivery order

1. Timecode measurement on real hardware (the open risk above), and service requirements checked.
   Result: for each camera pairing, the measured offset between the same moment on each feed, by
   filming a shared clock, before and after **Line up cameras**. **[Call]** A pairing passes if the measured error stays under one frame at the
   output rate over a 30 minute run. Pairings that fail still ship, as `Not aligned` with manual trim.
2. Portable engine and golden tests; local receiver.
3. Apple shell and single-camera streaming in one app; then Android shell.
4. Shared UI; adoption in all three apps; first hardware pass with a single camera.
5. Program switching with hard cuts on Z and Pocket multicam.
6. Timecode alignment and grades, for the pairings that passed milestone 1.
7. **[Owner]** Cable route for Pocket and Insta, once Wi-Fi streaming works: capture moved to shared code
   and added on Android and iPad. It is picture only, with no camera control or timecode on that route,
   so those cameras show `Not aligned` with manual trim unless also linked wirelessly. iPhone stays
   Wi-Fi only for these apps, and OpenZCine keeps its existing routes.
8. Desktop shell, delivered with project 2.

Single-camera streaming over Wi-Fi is useful on its own, so internal builds can follow milestone 4.

## Left to the builder

- Where exactly the clean-picture tap sits in each native runtime.
- Whether Apple's H.264 encoder shares code with `WatcherRelayEncoder` or stands alongside it.
- Exact tolerances, smoothing and retry timings within the stated limits.
- Module and type names, as long as the boundaries hold and `atlas check` passes.
