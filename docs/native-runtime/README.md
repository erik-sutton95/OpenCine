# Native monitor runtime

Apple processing belongs in `OpenCineApple`; Android processing belongs in `native-runtime`.
Portable transfer, scope and effects values belong in Media. Native modules depend downward on
Core, Media and platform codec/renderer modules, and have no UI, integration or app dependency.
UI takes immutable scope/image values and actions. App composition supplies native owners and
the camera's source profile.

The optional Android `appkit-native` module composes these native picture owners above
camera controls, decoder and native-runtime. Apps supply source epochs, calibration and
callbacks; UI consumes values and actions. Face readback binds pixels to the requesting
source and composition lifetime. Cache proof helpers compile only in androidTest.

Android `NativeGlBackend` and `NativeGlProgram` preserve the consuming app's existing graphics
helpers through a small typed adapter. Shader selection, effects passes, texture upload and
target lifetime belong in the shared runtime. The platform adds no graphics library dependency.
Applications supply raw color interpretation and source calibration as values or callbacks;
common algorithms do not infer those facts from a manufacturer.

Media owns portable assist options: detector RGB/sensitivity, zebra paint,
histogram/traffic-light compensation and anamorphic presets/correction. App
aliases retain their existing stored scalar values and labels; display swatches
remain theme bindings. Unknown source aspect stays absent in the common helper.
The Android source adapter retains its previous fallback geometry and Float
aspect arithmetic, while Apple uses Double geometry. Sampling is unchanged by
desqueeze, which corrects presentation only.

Media owns the portable `Peaking` reference detector, measured kernel constants and transfer
correction, together with zebra zone/stripe math. Peaking paint and sensitivity are aliases of
`MonitorPeakingColor` and `MonitorPeakingSense`, preserving their stored values. Apple rendering
and the vocabulary's Android feed-effects wire consume this calibration; app compatibility names
resolve to the same types. Frozen camera-frame corpus tests remain with the camera parser.

`ThermalTier` preserves the cosmetic 1/1/1.5/2 cadence policy used by non-program multicam
polling. The existing Android live-view wire validates its raw tiers but retains fixed cadence. Native scope sampling retains its separate, existing 1/1/3/5 load
policy. Neither policy changes recording commands or stream settings.

Media also owns the portable stereo meter values and `MonitorAudioMeterBallistics`.
The source passes linear peaks and elapsed seconds; the pure step returns a new
value with the existing instant attack, 26 dB/s level decay, 1.8 second peak hold
and 12 dB/s peak release. Camera wire indicators remain in their source adapters.
Known silence is a meter value; absent telemetry stays an
absent source observation rather than invoking a fabricated sample.

`MonitorPlaybackAudioMeterRuntime` owns the actual Apple audio tap, cancellable
track query and meter polling. Android `MonitorPcmAudioInput` owns prepared PCM
sampling; the app maps its player SDK encodings into `MonitorPcmFormat` and keeps
the SDK player/factory. Conform-preview mute policies remain application actions.
Neither owner introduces a player SDK dependency.

`MonitorPlaybackAudioSession` serializes Apple's synchronous audio-session setup
and release on its worker queue. Each app model retains one service across player
presentations. Leases keep the existing playback category, movie mode and
notification policy; host callbacks remain on Main. Retirement cannot block Main
on an entered audio RPC, and an old completion cannot release or report an error
for a successor lease. This Apple service changes scheduling, not the app's audio
policy; Android retains its existing native audio owner.

Each audio producer captures a source lease, and each format preparation captures
a sampling writer. Replacement and reprepare clear measured peaks and reject late
writes; a retired source cannot prepare or close its successor. The immutable peak
sample carries both generations so `MonitorAudioMeterSampler` resets held peaks
even if a new measurement arrives before polling sees the source transition.
Unmeasured source data stays absent, measured zero is silence, and owner close is
terminal. Android input close is tied to actual player disposal. Media playback
navigation and per-clip player selection remain application composition.

Each native owner has its own frame/sample publication lifetime. Replacing or retiring a source
must reject its late frames and clear only its own publications. Covers and rotation preserve
the picture host. Codec, frame leases, renderer scheduling and sampling demand retain one owner
through that host's lifetime. A captured frame is not permission to send a camera command.

`MonitorUIImageGraphProcessor` qualifies its baked-image memo with the prepared cube request
keys as well as source image identity and equal settings. A same-name stored LUT replacement
can therefore repaint a held source on its next render, while an unchanged cube still reuses
the memo. The retained Multiview fixtures exercise actual replacement pixels on both platforms;
Android already includes the shared library's render generation in its native renderer key.
These are simulated native checks; physical replacement behavior remains untested.

Android JPEG decoding stays on the source's decode worker. The frame pump awaits its optional
`publish` callback before synchronous frame observers or another decode. Bitmap Vulkan state
and UI frame publication belong on Main; the app rechecks source admission after that dispatch.
Glass and relay observers remain on the decode worker. Awaited publication preserves the pooled
bitmap's lifetime and rejects cancelled or retired work before observers run.

Verify portable changes on the mirrored Swift/Kotlin golden vectors, and runtime changes in the
actual consuming app. Include source replacement, cancellation and picture-host lifetime when
those paths change. Compile and simulated native checks are recorded separately from physical
camera qualification.

The GLES owner retains its EGL window, OES decoder surface, grading targets and bounded raw tap
through assist changes. A render-generation ticket fences asynchronous surface and present
callbacks across detach/re-attach. Each producer lease owns separate scope calibration/history;
late work cannot update a successor source. The app supplies source dimensions, clip profile,
transfer inference permission and display options, plus its existing graphics-helper factory.

Inspector previews belong to one monitor and retain one admitted job until delivery or discard.
Tickets also carry the current live/playback producer lease, so a retired source cannot publish
or invalidate a successor preview. Native backdrop workers deliver bounded immutable bitmap
publications; their private working raster is reused without changing retained UI pixels.
Consumer close retires admission and releases native workers; rotation only detaches the window.

The Android Vulkan owner builds on the existing `:vulkan` module. It owns ImageReader/AHB
delivery, GPU/window threads, presentation synchronization and source sampling. The app supplies
crash-guard, diagnostic and display-policy callbacks. The renderer's legacy `OpcVulkan` JNI class
and exports stay unchanged. Shared UI consumes immutable Media scope/traffic/axis values and
imports no native owner or sample bus. `atlas check` derives these downward edges from manifests.

Bitmap delivery keeps JPEG decoding on `MonitorFrameDecodeWorker`. A consumer whose picture
owner is confined to a different context supplies an awaited `publish` callback to
`monitorPumpFramesWithSourceFrame`; the source event and decoded bitmap cross together without
copying or resampling. OpenZCine publishes Bitmap presentation and Vulkan submission on Main,
then observes glass and relay frames on its decode worker. Retirement and cancellation are
checked again after publication. The dispatcher overload retains its existing delivery contract,
and the original overload defaults to caller-context delivery for existing consumers. This is
Android scheduling infrastructure; Apple retains its existing native presentation ownership.

Apple `MonitorLiveVideoRuntime` owns Annex-B format admission, the retained display layer,
one sticky VideoToolbox decoder, assist/decoded-source/preview demand and layer/Metal handoff.
Source configuration supplies calibration, transfer interpretation and diagnostics. The runtime
signals a random-access need; the integration's connection owner decides whether and how to
request it. `health` captures one source's format, reference, output and display facts, while
cached image repaint leaves its source freshness unchanged.

Capture `sourceToken` before queuing encoded or decoded input. `reset()` advances that source
identity without replacing the picture host; VT rebuilds also fence queued decoder output.
`close()` is terminal and cannot reopen or erase a successor publication lease. A pixel-buffer
source calls `preparePixelBufferSource` and submits through the same owner, preserving its token
through asynchronous delivery. Apps keep simulator footage selection and raw wire color mapping.

Native consumer callbacks may synchronously reset, rebuild or close their source. Decoded and
compressed presentation retain the admitted source token and decoder generation through source,
mirror, preview and diagnostic callbacks and recheck them before continuing. A retired completion
cannot commit its orientation, enqueue its pixels or refill source freshness after that callback.
Native consumer fixtures cover reset and terminal close during source delivery and mirror commit,
plus current-source acceptance and the existing cached-repaint and picture-owner cases.

Known live ISO reports use `updateSourceCalibration(iso:source:)` with a token captured before
queuing the report. Attach the sample bus before seeding a known ISO. This operation targets the
runtime's current live publication lease; the bus's display ceiling may belong to playback.
Invalid or retired reports preserve calibration and are refused. An unreported ISO (`nil`, zero or
less: Auto without its applied value) moves the ceiling to the profile's `unreportedISO` when it
names one (Luna I-Log: the lowest ISO, so clipping is never missed) and is otherwise refused. Android's existing
render policy already applies ISO to its current producer lease, so this Apple input adds no
second calibration owner or display-projection write.

Android already owns its encoded admission and MediaCodec/reference state in `:decoder`.
`MonitorSurfacePictureHost` and `MonitorTexturePictureHost` own the corresponding native View
attachment/listener lifetimes in `:native-runtime`, without a Compose dependency. The texture
program is either the existing GLES owner or a direct decoder surface. Old-window destroy and
update callbacks cannot release a replacement surface or refresh its presentation clock.

## Native media streaming

Apple `MonitorMediaHTTPStream` owns one bounded URLSession request and cancellation lifetime.
The app supplies its existing immutable configuration and source URL; the worker suspends while
its owned sink consumes chunks and refuses queued bytes above the supplied bound. Android
`MonitorMediaStreamPump` owns bounded reads, sink writes and cancellation of an app-supplied
`MonitorMediaReadSource`; the app keeps its existing HTTP client and socket policies. Neither
worker interprets asset identities or catalog records.

A positive HTTP Content-Length takes precedence over a known representation-size hint. Reaching
that length completes without another EOF read; absent lengths remain absent. Positive partial
EOF returns a receipt and the cache applies the explicitly supplied eligibility rule. Caller
cancellation retires a pending open/read and cannot become a successful receipt. Apple preserves
its donor whole-chunk completion; Android bounds reads to the remaining known bytes. Controlled
HTTP/native read fixtures exercise no-EOF completion, header precedence, cancellation and partial
receipts. `MonitorMediaThumbnailEncoder` owns packed NV12 video-range conversion to the existing
sRGB JPEG output with explicit stride and plane guards.

### Native clip player on Apple

`MonitorApplePlaybackOwner` owns the real AVPlayer item, output-before-replacement attachment,
readiness KVO/deadline, time/end observers and native seek completion. Its Media item token and
request identity fence every callback, suspension and multi-call native operation. Native track
metadata probes follow readiness instead of delaying transport; retired probes cannot publish
facts into a newer item. `MonitorPlaybackFeedSession` owns the moved
AVPlayer video-output/display-link/pull/assist pipeline, while `MonitorPlaybackFeedHost` retains
the actual identity player layer and processed picture siblings. Source profile, HDR display,
journal and frame-advanced notification are required or defaulted app facts/actions.

Main owns host/policy/source orchestration. The serial pull queue owns held buffers and parked
seek work and receives immutable source/effect snapshots. A short lock admits only enqueueing
existing assist-engine work; source or look retirement cannot wait on AVFoundation/CI work.
Old submissions cannot follow successor reset/history, and stale native seek/present callbacks
cannot kick, publish or hide the successor. Host ownership comes from the existing native
picture lease, so an old feed shutdown cannot clear another feed's host or sample source.
Native 420 video-range output, first-picture pulling, paused parking and identity/overlay/LUT
handoff remain the exercised donor policies. Android still uses the actual shared effects and
surface runtime through its small app Media3 adapter; shared modules add no Media3 dependency.

### Native media export on Apple

`MonitorMediaExporter` owns native copy/transcode, compatible-preset selection and fallback,
full-raster Core Image look baking, export-session progress and output readability. The caller
supplies the source and prepared destination URLs. `Look` takes a sampled Media cube, encoded
value preservation and an optional QuickTime metadata key/value replacement. Source-specific
curve selection and metadata keys stay in the app or integration adapter.

Same-format originals, and an ungraded M4V original exported as MP4, retain the byte-copy path.
Grading retains the source display raster and the existing compatible quality preference.
Optional Sendable/Encodable metadata writes a sibling `meta.json` only after the video becomes
readable, using sorted, pretty-printed JSON and ISO8601 dates. Applications keep their existing
storage namespace, filename policy and preparation progress before calling the native owner.

The first consuming app's unchanged native fixtures pass before and after adoption: encoded
sample preservation, both curve directions and embedded metadata, raster fitting, preset and
progress mapping. Shared filesystem fixtures cover original-byte preservation and optional
sidecar shape/absence. Physical-device export remains untested.

`MonitorReaderWriterMediaExporter` supplies the separate reader/writer operation for sources
whose readable media may end before their declared duration. It keeps native coded geometry,
the preferred transform, caller-prepared cubes, separate video/audio readers and atomic metadata
sidecars. A source with no decoded video is refused as `.failed`, whether its reader stops at a
missing sample or at undecodable data; a byte fraction alone does not establish readability.
`MonitorMovieFile` supplies container facts and progress-duration scaling, and
`MonitorMovieTimecode` copies existing timecode as a best-effort post-export operation. A partial
source skips timecode embedding. Apps retain destination storage, cube sampling and metadata policy.

Six synthetic iOS simulator scenarios exercise complete export, composition, LUT baking,
timecode and readable partial output. Native macOS reads the same generated partial fixture
nondeterministically, so its scenario overwrites the kept media bytes and proves refusal
instead. A separate native macOS proof exports the
readable prefix of an existing sample to a playable movie with metadata. Unreadable audio does
not imply readable video is absent. These are simulated and native framework checks; physical
devices and the consuming app's delivery workflow remain untested.

### Native movie export on Android

`MonitorNativeMovieExporter` owns each codec operation's completion, progress polling, monotonic
stall deadline and cancellation. The host supplies a typed codec factory for its existing native
SDK, retaining the original SDR working space and H264/AAC construction. Unknown progress remains
absent. Each operation captures its own completion; a canceled codec's late callback cannot
complete a successor. No codec SDK dependency is added to the shared module.

`MonitorMovieExportPreparer` owns approved-LUT preparation, transient output, MOV brand
finalization, timecode carry, bounded owned-cache pruning and cleanup. Original media remains
read-only. Metadata copying is best effort. Cleanup failures are suppressed on the original
export failure or cancellation. Application composition supplies approval, cache prefix, filename
fallback and operator error wording; camera and delivery policy stay outside the native runtime.

`MonitorMovieTimecode` moves the existing QuickTime box/sample copier. Its golden chunk-offset,
track-reference, no-timecode and existing-timecode cases remain unchanged in the consuming app.
The copied track's header and edit-list durations are rescaled to the export's movie timescale
(Media3 writes 10000; a camera proxy's 1000 copied raw would cut an 8 s track to 0.8 s).
Controlled codec tests and JVM file tests do not prove native encoding or physical-device
behavior; consuming apps also need real decoded video, audio, metadata and progress evidence.
OpenZCine's `NativeReadableMovieExportTest` supplies that evidence on an API 35 arm64 emulator
(SIMULATED input; physical devices untested).

## Swift CI compatibility scope

CI compiles the complete package and every test target with complete concurrency
checking, then runs that full test bundle. A separate scratch directory compiles
all 13 listed portable library/test targets with warnings treated as errors,
including Core, its test support and Multicam. The manifest and original test
sources remain intact; a runtime test filter does not limit compilation scope.

`OpenCineApple` and `OpenCineAppleTests` are explicitly outside the portable
warnings-as-errors gate. They remain in the full strict build/test and iOS build
checks. This is a native compatibility exception, not unchanged warning-as-error
coverage. Current SDKs warn on the retained Core Image kernel-language initializer
and compatible-export-preset query. Those warnings remain visible; CI suppresses
none of them. Replacing the kernels requires Metal-language implementation and
native pixel validation. The replacement preset API requires asynchronous
compatibility inspection and preserved preset/fallback behavior. A hygiene change
does not change those render/export policies.

See the [CI workflow](../../.github/workflows/ci.yml) and
[package manifest](../../Package.swift) for the exact targets and checks.

## First decoder-error context

The Apple monitor runtime captures the first access unit behind each decoder-error
episode. An optional `FeedIncidentDecodeErrorContext` records its numeric status,
ordered NAL types, byte count, IRAP and parameter-set-change ages, and recent input
rate. Later errors retain that context until native output starts a new episode;
source reset clears it and retired callbacks cannot publish it. It contains no
compressed payload, camera identifiers or user data.

PocketCine and InstaCine include that value in their shared decoder incident
snapshots. Kotlin uses the same bounded optional payload and JSON representation.
MediaCodec errors describe the codec rather than a particular access unit, so
Android producers leave this field absent. The Nikon JPEG source has no corresponding
access-unit producer. Existing incident records decode with the optional field
absent; its presence does not identify the field origin of damaged references.
