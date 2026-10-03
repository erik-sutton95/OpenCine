# Native monitor runtime

Apple processing belongs in `OpenCineApple`; Android processing belongs in `native-runtime`.
Portable transfer, scope and effects values belong in Media. Native modules depend downward on
Core, Media and platform codec/renderer modules, and have no UI, integration or app dependency.
UI takes immutable scope/image values and actions. App composition supplies native owners and
the camera's source profile.

Android `NativeGlBackend` and `NativeGlProgram` preserve the consuming app's existing graphics
helpers through a small typed adapter. Shader selection, effects passes, texture upload and
target lifetime belong in the shared runtime. The platform adds no graphics library dependency.
Applications supply raw color interpretation and source calibration as values or callbacks;
common algorithms do not infer those facts from a manufacturer.

Media also owns the portable stereo meter values and `MonitorAudioMeterBallistics`.
The source passes linear peaks and elapsed seconds; the pure step returns a new
value with the existing instant attack, 26 dB/s level decay, 1.8 second peak hold
and 12 dB/s peak release. Camera wire indicators and native audio taps remain in
their source adapters. Known silence is a meter value; absent telemetry stays an
absent source observation rather than invoking a fabricated sample.

Each native owner has its own frame/sample publication lifetime. Replacing or retiring a source
must reject its late frames and clear only its own publications. Covers and rotation preserve
the picture host. Codec, frame leases, renderer scheduling and sampling demand retain one owner
through that host's lifetime. A captured frame is not permission to send a camera command.

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

Android already owns its encoded admission and MediaCodec/reference state in `:decoder`.
`MonitorSurfacePictureHost` and `MonitorTexturePictureHost` own the corresponding native View
attachment/listener lifetimes in `:native-runtime`, without a Compose dependency. The texture
program is either the existing GLES owner or a direct decoder surface. Old-window destroy and
update callbacks cannot release a replacement surface or refresh its presentation clock.
