# Catalyst capture adoption

This is local candidate work for the approved OpenZCine Mac rebuild. It is not a released Core version or an integrated app pin.

The Apple capture owner accepts an optional device identifier and requested mode. Catalyst requires explicit selection and keeps a missing selected device disconnected. The existing iPad default still selects its first external device and uses its existing format ranking. Requested modes must match advertised dimensions and frame-rate ranges. Capture diagnostics distinguish received frames, AVFoundation drops and newest-frame replacement. Stopped sources are terminal, remove their notification tokens and refuse queued reconfiguration.

Catalyst excludes unavailable hotspot and WatchConnectivity implementations. The Watch product's conditional Apple dependency includes Catalyst for its remaining typed adapters. The playback audio adapter imports its native buffer-list modules explicitly. The shared Sharing configuration accepts optional host capability groups, defaulting to empty; OpenZCine supplies its Mac virtual-camera controls there.

| Consumer | Required adoption and evidence |
| --- | --- |
| OpenZCine | Mac-only device/mode selection, CI-buffer preview and native camera output use the new Apple configuration and optional Sharing groups. Local paired Core is required. Signed Catalyst build and iOS/Watch compile passed. Physical HDMI and sustained webcam performance remain unqualified. |
| OpenPocketCine | No camera-output controls are supplied. New parameters and Sharing groups have preserving defaults. No app source migration is required for these Mac APIs. A future Core pin adoption and consumer verification remain pending publication. |
| OpenInstaCine | Same preserving default contract; no Mac virtual-camera capability is supplied by this work. No app source migration is required. A future Core pin adoption and consumer verification remain pending publication. |
| Android | No native Android contract or behavior changed. CMIO, Catalyst packaging and Apple permission availability have no Android API twin. |

The task's exact app base is OpenZCine25b3875d and Core4ae6a3ea. Pocket59b004ad and Insta465f2477 were inspected read-only for direct UVC source construction; none was found. The atlas impact command reported missing local app checkouts, so its incomplete call-site output is not treated as consumer verification. App pins remain unchanged and do not contain this unpublished candidate.

Checks are recorded in the separate Mac task evidence: the full Core Swift suite passed; complete concurrency build passed; MonitorUI and OpenCineApple iOS builds passed; atlas tests passed197 with1skip and atlas check passed. The new selection/mode tests ran red before implementation and green afterward. The original parity233/251 acceptance ledger remains separate.

Shared changes require normal review, Core integration and relevant app pin verification before being described as integrated. Operator-visible performance must be measured on the actual capture chain; simulated, compile and ownership checks do not establish a frame-drop repair.
