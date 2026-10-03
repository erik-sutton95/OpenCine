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
