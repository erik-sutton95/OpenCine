# Routing

Use this to form a first ownership hypothesis, then confirm it in the target repo's
source and manifests at a pinned revision. "Shipped owner" is where the code lives on the
registered app baselines (`main`). "Shared home" is the target in the one platform repo
`opencine` that the apps' `opencine/integration` candidate branches consume; it stays
**candidate** until those branches merge (see `status` in `repos/<id>/meta.json`).

| User-visible behavior | Shipped owner | Shared home in `opencine` (candidate) | Evidence to follow |
|---|---|---|---|
| Menu gesture, drum/dial, HUD spacing, theme, scroll fade, page chrome | `openpocketcine` (`Sources/MonitorUI`, `Apps/Android/monitor-ui`); copies in Insta and Nikon engine-port | `Sources/MonitorUI`, `Android/monitor-ui` (layer ui) | Presentation tests, both platform implementations, each app's composition |
| Layout policy, capability projection for layout | `openpocketcine` `Sources/MonitorPresentation` | `Sources/MonitorPresentation` | `MonitorPresentationTests`, `MonitorCapabilities.swift` |
| Multi View tiles, retained hosts, per-camera settings, record-all | `openpocketcine` `ios/OpenPocketCine/Multiview*`; Nikon multicam only on engine-port | Engine: `Sources/OpenCineMulticam`, `Android/multicam`; UI stays in `Sources/MonitorUI` | Host identity, lease lifetime, record-plan invalidation |
| Scope math, LUT parsing, false color, log/709 analysis | `openpocketcine` `Sources/OpenPocketViewCore`; Nikon `Sources/OpenZCineCore` | `Sources/OpenCineMedia`, `Android/media` | Signal metadata, analysis configuration, golden fixtures (`Fixtures/`) |
| DJI pairing, DUML command, DJI log profile, station join | `openpocketcine` | `Sources/OpenCineDJI` (the Kotlin DJI session stays in the app) | Protocol mapping, replay fixtures, hardware evidence |
| Nikon PTP operation, Wi-Fi vs USB control, HDMI/UVC capture input | `openzcine` | `Sources/OpenCineNikon` (protocol); UVC capture in `Sources/OpenCineApple` | Transport ownership, picture/control independence |
| Owner-keyed JNI sessions | `openzcine` engine-port only | stays in each app's JNI facade | `AndroidSessionOwnerRegistry` and its tests on the candidate ref |
| Luna discovery, ILog/ColorRecovery, gimbal, setting readback | `openinstacine` (`Adapters/`, `Apps/Android/luna-adapter`, Luna-owned `ios/` files) | `Sources/Insta360Protocol`, `Sources/Insta360Apple`, `Android/insta360-luna`, `Android/insta360-shell` | Adapter, protocol package, delayed readback evidence |
| Frame.io delivery | `openzcine` (`Sources/OpenZCineCore/Frameio`, Android `frameio/`); `openpocketcine` `ios/OpenPocketCine/Frameio` | Optional `Sources/OpenCineFrameIO` | Request planning, OAuth/storage stay app-owned |
| Live decode, decoded-frame leases, Android Vulkan renderer | each app | `Sources/OpenCineApple`, `Android/vulkan` | Decoder admission, lease lifetime, JNI export set |
| Cross-brand composition (simulated) | none | `Sources/Harness*`, `Tests/HarnessTests`, `docs/harness/TOPOLOGY.md` | Simulated only; never hardware evidence |
| App icon, entitlement, signing, store notes, version | The brand app | The brand app | App build configuration |
| A shared product changed and an app stopped compiling | `opencine` first | | App pin (`opencine-pins.txt`), consumer build evidence, `atlas impact opencine` |

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
