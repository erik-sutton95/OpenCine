# Routing

Use this to form a first ownership hypothesis, then confirm it in the target repo's
source and manifests at a pinned revision. "Current owner" is where the code lives on the
registered baseline. "Destination" is the approved plan target and stays **proposed** until
an app actually consumes the package (see `status` in `repos/<id>/meta.json`).

| User-visible behavior | Current owner | Destination (proposed) | Evidence to follow |
|---|---|---|---|
| Menu gesture, drum/dial, HUD spacing, theme, scroll fade, page chrome | `openpocketcine` (`Sources/MonitorUI`, `Apps/Android/monitor-ui`); copies in Insta and Nikon engine-port | `opencineui` | Presentation tests, both platform implementations, each app's composition |
| Layout policy, capability projection for layout | `openpocketcine` `Sources/MonitorPresentation` | `opencineui` | `MonitorPresentationTests`, `MonitorCapabilities.swift` |
| Multi View tiles, retained hosts, per-camera settings, record-all | `openpocketcine` `ios/OpenPocketCine/Multiview*`; Nikon multicam only on engine-port | Engine: `OpenCineMulticam` (not created); UI: `opencineui` | Host identity, lease lifetime, record-plan invalidation |
| Scope math, LUT parsing, false color, log/709 analysis | `openpocketcine` `Sources/OpenPocketViewCore`; Nikon `Sources/OpenZCineCore` | `OpenCineMedia` in `opencinecore` | Signal metadata, analysis configuration, golden fixtures |
| DJI pairing, DUML command, DJI log profile, station join | `openpocketcine` | `OpenCineDJI` (not created) | Protocol mapping, replay fixtures, hardware evidence |
| Nikon PTP operation, Wi-Fi vs USB control, HDMI/UVC capture input | `openzcine` | `OpenCineNikon` (protocol); capture source in Core's Apple/Android runtime | Transport ownership, picture/control independence |
| Owner-keyed JNI sessions | `openzcine` engine-port only | Core native runtime | `AndroidSessionOwnerRegistry` and its tests on the candidate ref |
| Luna discovery, ILog/ColorRecovery, gimbal, setting readback | `openinstacine` (`Adapters/`, `Apps/Android/luna-adapter`, Luna-owned `ios/` files) | `OpenCineInsta360` (not created) | Adapter, protocol package, delayed readback evidence |
| Frame.io delivery | `openzcine` (`Sources/OpenZCineCore/Frameio`, Android `frameio/`); `openpocketcine` `ios/OpenPocketCine/Frameio` | Optional `OpenCineFrameIO` in `opencinecore` | Request planning, OAuth/storage stay app-owned |
| App icon, entitlement, signing, store notes, version | The brand app | The brand app | App build configuration |
| A shared package changed and an app stopped compiling | Package owner first | | App pin/lockfile, consumer build evidence, `atlas impact` |

## Wrong-repository traps

- A file under Insta's `Sources/MonitorUI` or most of `ios/` is a Pocket copy. Fix it in
  the donor, then sync.
- A file in Nikon's `Sources/MonitorUI` exists only on the engine-port candidate.
- Inherited Multi View code in Insta does not mean Luna Multi View is supported.
- An `Osmo*` file name in Insta (`OsmoMonitorPresentation.swift`) is Luna-owned code that
  kept the upstream name.

## Not every request needs a code change

Questions about merge state, support status, qualification or which revision ships a fix
are answered from refs, docs and evidence. Say so instead of proposing an edit.
