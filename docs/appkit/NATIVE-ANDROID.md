# Android native app composition

The optional `appkit-native` module is the Android composition counterpart of
`OpenCineAppKitApple`. It assembles the existing neutral decoder, picture hosts,
scope/preview owners and shared camera-control presentation. `appkit` stays
portable and camera-controls retains its original native import guard.

`MonitorLiveFeedSource` supplies the real HEVC session and its optional face-frame
adapter. `MonitorLiveFeedIntegration` supplies calibration, diagnostics and native
presentation choices. The common host retains native attachment, fallback,
backdrop, face readback, cover and recovery ownership; Pocket and Insta compose
their existing operator chrome around its returned picture and geometry.

The new host types were introduced only in the unfinished F11 source candidate.
They now live in `com.opencapture.opencine.appkitnative`; both candidate consumers
migrate together. Existing accepted camera-controls types keep their signatures.
The JPEG source does not use this HEVC assembly and remains a native-runtime
adapter. There is no integration or app dependency and no added library.

Module rules and actual surface lifetime/fallback tests verify the assembly.
Automated source qualification and physical camera qualification are separate;
this source candidate remains unverified until the recorded consumer gates pass.
