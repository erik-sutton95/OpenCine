# 1080p streaming for Osmo cameras: design

Date: 2026-11-21. Status: approved by the owner on 2026-11-21. Plan: `docs/superpowers/plans/2026-11-21-dji-1080p-streaming.md`.

## Intent

The owner reminded us that DJI Osmo cameras have a 1080p livestream mode, while our live streaming
(merged 2026-11-20) sends the camera's wireless live view, which is about 720p. The owner wants
1080p out of an Osmo camera through the same Go Live flow, the same destination and the same Live
pill, and wants to keep a way to stream with a custom LUT.

A throwaway hardware spike on 2026-11-21 (local branches `spike/dji-1080p-relay` in OpenCine and
OpenPocketCine) proved the relay on a Pocket 4 Pro and showed that the camera refuses log in
livestream mode. The owner then chose two Quality choices (2026-11-21):

1. **1080p native:** the camera encodes 1080p itself and publishes it to the phone, and the phone
   relays it to the destination. The picture is Rec.709. No color profile control, no LUT.
2. **1080p upscaled:** today's live view picture, with the operator's LUT, scaled up to a 1080p
   output.

The owner rejected converting the Rec.709 native picture back into a log curve on the phone so log
LUTs could apply to it (2026-11-21).

## Goals

- A Pocket 4 Pro operator can go live in 1080p native from the same Go Live control, with the
  same service, key and Live pill as today.
- Any operator whose camera feed is below 1080p can choose a 1080p upscaled output that keeps
  their LUT.
- The camera is always left in a healthy state: a stopped or failed native stream ends the
  camera's livestream and the camera returns to normal use.
- iOS and Android behave the same (house rule: Swift and Kotlin twins).

## Non-goals

- Log, a LUT or any color control in 1080p native. The camera refuses it (evidence below).
- Re-encoding the native picture into a log curve on the phone (owner, 2026-11-21).
- 1080p native on cameras without a livestream mode (Osmo Nano: DJI's guide says it has none),
  or on non-DJI cameras.
- The full monitor (assists, scopes, camera controls) on the native picture in the first release.
- Multicam switching with a native source (spec part 4 stays as planned for live view sources).
- Recording the relayed stream on the phone.

## Anti-goals (a failure even if it works)

- Leaving the camera stuck in livestream mode. On 2026-11-21 an app killed mid-stream twice left
  the Pocket 4 Pro unresponsive until a 10 second hard reset.
- Calling the upscaled output "1080p" without saying it is upscaled. The original streaming spec
  promised the stream "never pretends to more" than the source; the upscaled choice is allowed by
  the owner only as a clearly named choice.
- Brand names in shared code. Core and shared UI stay brand-free; the DJI integration declares the
  native capability.

## Evidence from the spike (Pocket 4 Pro, firmware as owned on 2026-11-21)

- **Provisioning over BLE (after normal pairing):** `02/8E` end (cleanup), `02/E1 1A` enter
  livestream mode, `07/47` join the shared network (first attempt often `01 FF`, the retry
  `00 00`), `08/78` configure (version `01`: 9 preset bytes then JSON with `rtmpAddress`, `codec`,
  `EnhancedRTMP`, `supportStopLive`, `watermark`, `orientation`), `02/8E` start. Wire format
  follows Moblin (MIT), credited.
- **Output:** HEVC over Enhanced RTMP, 1920x1080, 30 fps, about 6 Mbps, AAC-LC 48 kHz stereo,
  tagged Rec.709 8-bit. Received by an RTMP receiver in the app at `rtmp://<phone>:1935/live/<key>`.
- **Networks:** the iPhone hotspot (camera at 172.20.10.x) and a home Wi-Fi both worked.
- **Relay:** decoded with VideoToolbox (about 3 ms a frame) and relayed through the existing
  engine to YouTube for 12+ minutes with no gaps, stalls or decode errors.
- **Control while live:** the normal Wi-Fi control session (UDP 9004 with the TCP 7001 poke) opens
  at the publisher's LAN address while live without disturbing the stream. The camera reports
  color mode Normal.
- **Log refused:** `02/42` color SET of D-Log2, D-Log and D-Log M replies `EE` over Wi-Fi (no
  reply at all over BLE); Normal replies `00`. Picture statistics never change. Varying the two
  preset mode bytes (`02 00`, `02 02`, `03 01`) changes nothing.
- **Clean stop:** `02/8E` end, then closing BLE, leaves the camera healthy; its normal connection
  works afterwards.
- **Station join quirk:** the same day the camera answered `07/39` with `00 08` and `02/E1 01`
  with `DA`, values never recorded before. The shared `StationJoin` refused, which broke the
  per-camera Wi-Fi setup. Trying `07/48 01` once with the `00 01` readback fixed it.
- **Unverified:** Pocket 3 (version `00` binary form, H.264, mode byte question), Pocket 4,
  camera H.264 output, end-to-end latency, Android.

## Constraints from the code today

- Streaming: `LiveStreamCoordinator` (Swift `OpenCineAppKitApple`, Kotlin `appkit-native`) takes
  a `LiveStreamHost` with `route`, `source` (`StreamSourceFormat`) and `attachPicture` (the clean
  picture tap). `StreamPictureFitter` already scales any source to a fixed output size.
- Quality today follows the source: 720p for wireless feeds, 1080p only for a real 1080p source
  (spec `2026-11-05-rtmps-streaming-design.md`, Quality). `docs/streaming/ui-contract.md` holds the
  copy.
- The portable engine `OpenCineStreaming` runs on both platforms (Android through the JNI facade).
  The spike's `RTMPReceiveSession` is portable and belongs there.
- DJI BLE provisioning lives in `OpenCineDJI` (commands) and `OpenCineDJIApple` /
  Android `:dji` (links). Saved shared networks come from Multiview and the per-camera Wi-Fi setup.
- Streaming eligibility: shared Wi-Fi and phone hotspot routes are allowed; the camera's own Wi-Fi
  is blocked (no internet).

## Approaches considered

1. **Two Quality choices: native relay and upscaled live view (chosen by the owner).** Native is a
   new source kind that the DJI integration declares; upscaled is a new output size for any sub-1080p
   source. Pros: 1080p either way, the LUT stays available, one Go Live flow. Cons: two paths to
   explain; native drops the LUT.
2. **Native relay only, with a phone-side log conversion for LUTs.** Rejected by the owner.
3. **Camera publishes straight to the service.** No phone hop and no extra delay, but it gives up
   the shared destination handling, the Live pill state and re-encoding (Pocket 4 HEVC over
   Enhanced RTMP is not accepted everywhere). Superseded by the owner's relay request.

## Design

### Quality choices

The Quality row gains choices only where they apply:

| Choice | Offered when | Picture | LUT |
| --- | --- | --- | --- |
| Camera feed (today) | always | the live view at its own size, 720p for Osmo | yes |
| 1080p upscaled | the selected source is below 1080p | the live view scaled to 1920x1080 | yes |
| 1080p from camera | the integration declares native streaming for the selected camera and a shared network is available | the camera's own 1080p, relayed | no |

- Labels and the one-line explanations under each are in the UI contract and carry no brand.
  Proposed copy: "1080p upscaled: the camera feed scaled up, with your LUT" and "1080p from camera:
  sharper picture, encoded by the camera, standard color, no LUT".
- Bitrate follows today's table: about 6 Mbps at 1080p for both new choices.
- The choice is remembered per app like the service.

### 1080p upscaled

- Only the output size changes: the coordinator builds the fitter and encoder at 1920x1080 (or the
  16:9 frame matching the source shape) instead of the source size.
- The LUT path keeps its own width cap lifted (the spike lifted the 1440 working-width cap with a
  LUT on).
- Vertical presets keep their center crop; the upscale applies before the crop is scaled.
- Every app and both platforms get it (any sub-1080p source: Osmo, Luna, Nikon).

### 1080p from camera (native relay)

**Capability.** Core gains a brand-free capability an integration can declare for a camera:
"can publish its own stream to an address", with the codecs and frame rates it supports and
whether its picture can take a LUT (`false` for DJI). The DJI integration declares it for
Pocket 4 Pro now. Pocket 4 and Pocket 3 are declared experimental until someone confirms them on
hardware; experimental models need the existing experimental switch.

**Receiver.** `RTMPReceiveSession` (portable, `OpenCineStreaming`) handles the server side: the
handshake, connect / createStream / publish replies, acks, AVC, legacy and Enhanced RTMP HEVC,
and AAC. Each platform shell supplies the listener (Apple `NWListener`; Android a socket on the
same port) and the decoder (VideoToolbox; `MediaCodec`). Only the expected publisher is accepted:
the stream key is a fresh random token per session, and the receiver closes any other connection.

**Where it starts [Call].** From a single camera only, not from a Multiview stage (matches the
multicam non-goal). After Stop the app returns to its normal connect flow for that camera; the
spike showed the camera's normal connection works afterwards without an explicit `07/48 00`.

**Network [Call].** "Available" means at least one network saved in the shared network store
(Multiview and the per-camera Wi-Fi setup write it); iOS cannot see whether Personal Hotspot is on.
With one saved network it is used; with several, Go Live asks once, the phone hotspot first. With
none, the native choice still shows, disabled, with one line pointing to the camera's Wi-Fi setup.

**Start sequence (shared, DJI side).**
1. The camera must be idle (not connected for monitoring) or the app first releases it, the same
   way Multiview takes the radio.
2. Join the chosen network on the phone if needed (not for the hotspot).
3. Open the receiver, then BLE: end (cleanup), enter livestream mode, join, configure with
   `rtmp://<phone address>:1935/live/<token>`, start.
4. Go live outward only after the first decoded picture, so the stream never starts black.

**Picture and sound.**
- The decoded picture goes to the clean picture tap without a LUT, then through the fitter and the
  existing encoder (H.264 out, so Pocket 4 HEVC reaches every service).
- Sound [Call]: native mode sends the camera's own sound (decoded from its AAC) and does not ask
  for the microphone. No new sound row in the UI; the other choices keep today's microphone audio.
- Timestamps: the camera's RTMP timestamps are re-based onto the outgoing clock; a camera gap is
  sent as a gap, not stretched.

**What the operator sees.** The monitor area shows the relayed 1080p picture with the Live pill and
the usual stream status. Assists, scopes and camera controls are not available in this mode in
the first release and the screen says so in one line.

**Stop and failure.**
- Stop always sends `02/8E` end and waits for its reply (bounded), then closes BLE and the
  receiver. The camera then returns to normal use.
- If the camera's stream drops while live [Call], the outgoing stream stays up with today's
  behavior for a lost camera (hold the last frame 2 seconds, then the slate) while the app ends
  the camera's livestream cleanly and retries once in the background. If that fails, the slate
  stays and the operator sees Retry; ending the outgoing stream stays the operator's action.
- A start error before going live (for example `D6`) gets the same clean end and one retry.
- When the app goes to the background or is about to terminate while native streaming, it sends
  the end command first (best effort). Every start sends the cleanup end first.
- **Not yet proven [Call]:** on 2026-11-21 a camera left live by a killed app accepted the next
  cleanup end, then answered start with `D6` and stopped responding until a hard reset. The plan's
  first hardware task investigates recovery (for example `supportStopLive: true`, or waiting for a
  camera-side timeout). Until it is proven, a camera that stops answering gets plain recovery copy:
  hold the power button about 10 seconds to restart it.

### Station join fix (separate small PR)

`MulticamStationPolicy` treats an unrecognized two-byte role reply (`00 xx`) like AP: it sends
`07/48 01` once and still requires the `00 01` readback. The unexpected value is written to the
diagnostics journal. Swift and Kotlin together with their tests. This also unblocks the per-camera
Wi-Fi setup the owner hit on 2026-11-21.

### Where the work lands

- OpenCine: capability, receiver, DJI livestream commands (Swift and Kotlin), coordinator changes
  for both choices, UI contract copy, platform listener and decoder, the station join fix.
- OpenPocketCine: host wiring (saved networks, radio hand-off), and the hardware checklist.
- OpenInstaCine and OpenZCine: the upscaled choice arrives with the pin move; no app code expected.
- Platforms [Call]: Swift and Kotlin are built together (house rule), but the native capability
  stays hidden on Android until it passes a hardware check, so Android hardware risk does not
  block iOS. The upscaled choice ships on both at once.

### Tests

- Receiver: the spike's ffmpeg harness (H.264, H.264 with B-frames, HEVC) as an opt-in test, plus
  fixture-based unit tests that run in CI on both platforms.
- Commands: byte-exact tests for `02/E1`, `08/78` version `01` (and `00`), `02/8E` start and end
  against the captured frames.
- Coordinator: choice availability per source and capability, clean stop on every exit path,
  retry after a start error.
- Station policy: the `00 08` case on both platforms.
- Hardware checklist (owner, live page): Pocket 4 Pro on hotspot and home Wi-Fi, 30 minute soak,
  clean stop, background and kill recovery, camera audio, upscaled with LUT on Pocket and Luna.

## Left to the builder

- Type and file names, and how the capability is shaped in Core and Kotlin.
- The Android listener and `MediaCodec` details, as long as behavior matches iOS.
- Whether camera AAC is decoded to PCM for the existing audio encoder or passed through.
- Exact upscale filter (the fitter's Core Image scale is acceptable).
- How the receiver token is generated and logged (never the full token in a log).
- Latency measurement method for the checklist.
