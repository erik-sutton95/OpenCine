# Retired app owners (thin-app migration)

Which app-owned code moved to which OpenCine owner on `integration/thin-app`, with the commits
that did it, and how much production code each app still carries. Companion of the
[tester guide](TESTER-GUIDE.md): a row here is where a regression in that area would come from.

Status: candidate. Automated checks passed on simulators and emulators; physical hardware is
untested on every changed platform. Several lanes are still landing (see
[Not retired yet](#not-retired-yet)), so the revisions and counts below are a snapshot.

## Snapshot

| Repository | `main` | `integration/thin-app` | Commits `main..integration/thin-app` (no merges) |
|---|---|---|---|
| OpenCine | `d739bbdb` | `6133cf67` | 38 (30) |
| OpenPocketCine | `27b15028` | `ae864436` | 134 (113) |
| OpenInstaCine | `35b6f33b` | `67c42504` | 168 (142) |
| OpenZCine | `9ac41387` (origin/main) | `227bd272` | 128 (117) |

Taken 2026-10-05. OpenZCine's local `main` branch (`f1ccfcfd`) is 9 commits behind `origin/main`;
this inventory uses `origin/main`, which `integration/thin-app` contains. On `main` none of the
three apps depended on OpenCine (no `opencine-pins.txt`): every OpenCine owner below is new to the
apps. Most OpenCine owners already existed on OpenCine `main`; the "OpenCine commits" column lists
only the owners added on `integration/thin-app`.

## Production line counts

Production code is every tracked `.swift`, `.kt`, `.java`, `.m`, `.mm`, `.c`, `.cc`, `.cpp`,
`.h`, `.hpp`, `.metal`, `.glsl`, `.agsl`, `.frag`, `.vert` and `.comp` file, excluding tests
(`Tests/`, `*Tests/`, `src/test*`, `src/androidTest*`, `testFixtures/`, `Fixtures/`), build
manifests (`Package.swift`, `*.kts`) and developer tooling (`tools/`, `scripts/`, `handbook/`,
`reference/`, `atlas/`).

| Repository | `main` | `integration/thin-app` | Change |
|---|---:|---:|---:|
| OpenPocketCine | 172,466 lines, 573 files | 87,486 lines, 341 files | -84,980 (-49%) |
| OpenInstaCine | 174,997 lines, 619 files | 87,141 lines, 366 files | -87,856 (-50%) |
| OpenZCine | 190,396 lines, 357 files | 139,327 lines, 292 files | -51,069 (-27%) |
| Three apps | 537,859 | 313,954 | -223,905 (-42%) |
| OpenCine (shared) | 159,489 lines, 756 files | 181,063 lines, 829 files | +21,574 |
| Everything | 697,348 | 495,017 | -202,331 (-29%) |

Tests shrink less, by design (tests of removed code go with it; live assertions stay): app test
lines Pocket 66,785 to 51,260, Insta 66,310 to 55,661, Nikon 62,848 to 56,800.

Per directory (production lines, `main` to `integration/thin-app`):

| App | Directory | `main` | `integration/thin-app` |
|---|---|---:|---:|
| Pocket | `Apps/Android` | 77,437 | 37,161 |
| Pocket | `ios/OpenPocketCine` | 62,933 | 45,406 |
| Pocket | `Sources/OpenPocketViewCore` | 19,555 | 3,745 |
| Pocket | `Sources/MonitorUI`, `Sources/MonitorPresentation` | 9,710 | 0 (moved to OpenCine) |
| Pocket | `Sources/OpenPocketCineAndroidFacade` | 2,352 | 707 |
| Pocket | `ios/OpenPocketCineWatch`, `Sources/CJNI` | 479 | 467 |
| Insta | `Apps/Android` | 75,817 | 37,413 |
| Insta | `ios/OpenInstaCine` | 59,718 | 34,201 |
| Insta | `Sources/OpenPocketViewCore` (Pocket copy) | 19,673 | 14,150 |
| Insta | `Sources/MonitorUI`, `Sources/MonitorPresentation`, `Sources/MonitorContracts` | 9,971 | 0 (moved or deleted) |
| Insta | `Adapters/Insta360Protocol`, `Adapters/Insta360Apple` | 6,987 | 0 (moved to OpenCine) |
| Insta | `Sources/OpenPocketCineAndroidFacade` | 2,352 | 910 |
| Insta | `ios/OpenInstaCineWatch`, `Sources/CJNI` | 479 | 467 |
| Nikon | `Apps/Android` | 89,710 | 74,139 |
| Nikon | `ios/Runner` | 63,273 | 49,912 |
| Nikon | `Sources/OpenZCineCore` | 25,279 | 12,545 |
| Nikon | `Sources/OpenZCineAndroidFacade` | 11,529 | 2,136 |
| Nikon | `ios/OpenZCineWatch`, `Sources/CJNI` | 605 | 595 |

### Refresh

Run from the folder that holds the four checkouts side by side (`<app> main` is `origin/main`
for the apps, `main` for OpenCine):

```sh
SPEC=('*.swift' '*.kt' '*.java' '*.m' '*.mm' '*.c' '*.cc' '*.cpp' '*.h' '*.hpp' '*.metal'
  '*.glsl' '*.agsl' '*.frag' '*.vert' '*.comp'
  ':(exclude)Package.swift' ':(exclude)tools' ':(exclude)scripts' ':(exclude)handbook'
  ':(exclude)reference' ':(exclude)Tests' ':(exclude)atlas' ':(exclude,glob)**/*Tests/**'
  ':(exclude,glob)**/src/test*/**' ':(exclude,glob)**/src/androidTest*/**'
  ':(exclude,glob)**/testFixtures/**' ':(exclude,glob)**/Fixtures/**')
for r in OpenPocketCine OpenInstaCine OpenZCine OpenCine; do
  base=origin/main; [ "$r" = OpenCine ] && base=main
  for ref in "$base" integration/thin-app; do
    git -C "$r" grep -c '' "$ref" -- "${SPEC[@]}" |
      awk -F: -v r="$r" -v ref="$ref" '{ n += $NF; f++ } END { print r, ref, f " files", n " lines" }'
  done
done
for r in OpenCine OpenPocketCine OpenInstaCine OpenZCine; do
  base=origin/main; [ "$r" = OpenCine ] && base=main
  git -C "$r" log --reverse --no-merges --format='%h %s' "$base..integration/thin-app"
done
```

The checkpoint ledger is `~/Work/OpenCine-Execution-Progress.d/MIGRATION-CHECKPOINTS.json`
(machine-local; rows `<app>.<area>`).

## OpenPocketCine

| App code on `main` | Now owned by (Swift / Android) | App commits | OpenCine commits |
|---|---|---|---|
| UI 2.0 design system (`Sources/MonitorUI`, `Sources/MonitorPresentation`, Android `monitor-ui`) | `MonitorUI`, `MonitorPresentation` / `monitor-ui` | `8a5de7c8`, `ec28f994`, `c53d78ed` | |
| Camera control seam (ISO, white balance, record, `ObservedValue`, receipts); legacy Kotlin `core-api` `CameraSession` seam retired | `OpenCineCore` / `core` | `0ec37854`, `75d06195`, `58fd6763`, `4899a92b`, `44d8451e` | |
| Media math (scope ceilings, H.26x NAL, present policy, freeze bound, decoder policy) | `OpenCineMedia` / `media` | `19ce492d`, `5bc96f39`, `0ff4f1e3`, `52eb9e5f` | `af6cb4f` |
| DJI protocol, wire and session (Swift), Kotlin DJI layer and session, `DjiNative` exports | `OpenCineDJI`, `OpenCineDJIAndroid` / `dji` | `b0590efb`, `2c7f85c7`, `b458ba85`, `1e2c4443`, `85ce20fa`, `c0a534c4` | |
| Apple DJI transports, control exchange, connection bootstrap, camera controls, gimbal control | `OpenCineDJIApple` | `fa733387`, `4c55affe`, `d618e7cb`, `ef5ea72f`, `06ffd875`, `63ac13eb` | `46d5f9f`, `8b21013` |
| Picture recovery, recovery episode, scoped live-view recovery, heartbeat | `OpenCineDJIApple`, `OpenCineApple` | `aa845001`, `06790160`, `cc3f5816`, `0128d19b`, `417c9d6b` | `1c71cb3`, `929a94d` |
| Live video decode and render (HEVC on VideoToolbox; Android decoder and Vulkan renderer) | `OpenCineApple` / `decoder`, `vulkan` | `377205f4`, `69706fda`, `a76488ad` | |
| Native video, feed and effects runtime | `OpenCineApple` / `native-runtime` | `299fad83`, `39bf5a82` | `f06495a` |
| Assist state, sampling, inspector and views | `OpenCineApple`, `MonitorUI`, `OpenCineAppKit` / `native-runtime`, `monitor-ui`, `appkit` | `82248663` | `f06495a` |
| Cameras and pairing flow, saved cameras, setup naming and legal links | `OpenCineAppKit` / `appkit` | `f488e5f7`, `23e89d02` | |
| Live layout from the body's declared capabilities | `OpenCineDJI` over `OpenCineCore` capability contracts | `426cbe95`, `c4133304` | |
| Root, monitor screen and lifetime, capture and system controls, Display preferences | `OpenCineAppKit`, `MonitorUI` / `appkit`, `monitor-ui` | `a96f3d9e`, `0d8d713a`, `b0dd740b`, `5ba8f1af` | |
| Operator settings | `OpenCineAppKit`, `MonitorUI` / `appkit`, `monitor-ui` | `57f8c037` | `1342baa` |
| Media browse producer, library, cache and selection | `OpenCineDJI`, `OpenCineDJIApple`, `OpenCineAppKit` / `dji`, `appkit` | `cc97a3d8`, `82248663` | `a3be9a8` |
| Playback (feed, audio, page) | `OpenCineApple`, `MonitorUI` / `monitor-ui` | `39bf5a82` | `31f4894`, `ced835b` |
| Clip export (Apple) | `OpenCineApple` | `6907bcb5` | `f818bd3`, `8925819` |
| Frame.io workflow and delivery | `OpenCineFrameIO`, `OpenCineAppKit` / `appkit` | `f569e4f5`, `82248663` | `bdff6e9`, `435047e`, `d79b371`, `e3ee6de`, `213a014` |
| Multiview (group and tile record, editor leases, qualification, app budget) | `OpenCineMulticam` / `multicam` | `de7928a9`, `6f01b258`, `5d5e3652` | |
| Gimbal trajectory math | `OpenCineMotion` | `63187113` | |
| Watcher relay wire | `OpenCineRelay` | `0ad71861` | |
| JNI copy helpers, neutral Android platform and storage | `OpenCineJNISupport` / `platform` | `0d8a7b9a`, `7e97510c` | |

Stays in the app: brand, entitlements, integration list, the iOS `CameraSession` composition
and its neutral compatibility owners (pocket.integration, partial), the Watch app, the
Android facade and app-specific panels.

## OpenInstaCine

| App code on `main` | Now owned by (Swift / Android) | App commits | OpenCine commits |
|---|---|---|---|
| UI 2.0 design system (synced copy of Pocket's) | `MonitorUI`, `MonitorPresentation` / `monitor-ui` | `5245b5f`, `464f902`, `b7783ba` | |
| Camera control seam (ISO, shutter, white balance, record); command half of `MonitorContracts` dropped | `OpenCineCore` / `core` | `4992775`, `6247344`, `04f6413`, `7fbdd3a`, `7353aa7` | |
| Media math (scope ceilings, NAL, present policy, decoder policy) | `OpenCineMedia` / `media` | `ca1d77b`, `e93c48f`, `e2d0bf7` | |
| Luna protocol and Apple transport (`Adapters/Insta360Protocol`, `Adapters/Insta360Apple`) | `Insta360Protocol`, `Insta360Apple` (+ `CKcp`) | `842eb18` | |
| Android shell contract and Luna adapter | `insta360-shell`, `insta360-luna` | `9f5ee09` | |
| Live video decode and render | `OpenCineApple` / `decoder`, `vulkan` | `b1e6984`, `65ff59b`, `e3e03ce` | |
| Native runtime: GLES effects, assist rasters, presenter, scoped previews, live video | `OpenCineApple` / `native-runtime`, `vulkan` | `8b1a087`, `fb33db1`, `56a1024`, `a86ea78`, `ef2b1ec`, `a174945` | |
| Assists: scopes, histogram, false color, RGB meter, audio meters, level overlay, ND suggestions, tracking and focus marks, assist catalog, options, state and inspector | `MonitorUI`, `OpenCineMedia`, `OpenCineApple` / `monitor-ui`, `media` | `b194312`, `a073d59`, `07bacad`, `156155c`, `f68a7e7`, `68cf52f`, `39cc3fc`, `918c23b`, `ebb7a54`, `2665a8a`, `ae5d030`, `9052699`, `3296b88`, `1c3d29c`, `03ce681` | `f06495a` |
| Live layout from the camera's declared capabilities | `Insta360Apple` (`LunaCameraSession.layout`) over `OpenCineCore` capability contracts | `7528059` | |
| Cameras and pairing flow | `OpenCineAppKit` / `appkit` | `a03cfdc`, `56fbce9`, `c97e9e0`, `689523a` | |
| Root, monitor lifetime, common, capture and system controls; zoom and focus receipts | `OpenCineAppKit`, `MonitorUI` / `appkit`, `monitor-ui` | `e5d11c3`, `0c19768`, `3e890ab`, `15bc06a`, `250aea7` | |
| Operator settings (page, safety, motion, connection, display, assist, sharing, tool usage, exposure and look cards) | `OpenCineAppKit`, `MonitorUI` / `appkit`, `monitor-ui` | `ec8efb0`, `bd57428`, `63ac329`, `76ed792`, `024282e`, `b69eb2f`, `a199121`, `d3c41c6`, `c44928c`, `6c743f6` | `1342baa` |
| Media producer, library, cache and gallery | `OpenCineAppKit`, `OpenCineMedia` / `appkit`, `media` | `655bdbb`, `8273e57` | |
| Playback (composition, native and audio owners) | `MonitorUI`, `OpenCineApple` / `monitor-ui` | `d4dd2d2`, `1bea7f1`, `f1b82ab` | `31f4894`, `ced835b` |
| Clip export (Apple) | `OpenCineApple` | `0b2da92` | `f818bd3` |
| Frame.io client, batch, internet handoff, delivery panel and lifetime | `OpenCineFrameIO`, `OpenCineAppKit`, `MonitorUI` | `f01dca3`, `d698ae0`, `9999220`, `f77c0b3`, `9ef2c5f` | `bdff6e9`, `435047e`, `d79b371`, `4203424`, `9836291` |
| Gimbal trajectory math | `OpenCineMotion` | `1b67ba7` | |
| Watcher relay wire | `OpenCineRelay` | `0aaac91` | |
| JNI helpers, neutral media and storage utilities | `OpenCineJNISupport` / `platform`, `media` | `97696ee`, `879266c` | |
| DJI code the Luna build never ran (deleted, not moved) | | `6a1da8b`, `e9d7dc8` | |
| Source sync from OpenPocketCine (scripts, overlays, stamp) | retired | `705d316`, `67c4250` | |

Stays in the app: brand, entitlements, `LunaIntegrationConfiguration`, the Watch app, the
Android facade, and `Sources/OpenPocketViewCore` (14,150 lines, a remaining copy of Pocket's
view core that the insta lane is extracting into OpenCine).

## OpenZCine

| App code on `main` | Now owned by (Swift / Android) | App commits | OpenCine commits |
|---|---|---|---|
| Camera control seam (ISO, white balance, record); every facade session call names its connection owner | `OpenCineCore` / `core` | `e8fe1d20`, `3b0dfd01`, `6bce2301`, `3e960849` | |
| Media math (`CubeLUT`, `FrameRateSampler`) | `OpenCineMedia` / `media` | `ba1e340b` | |
| Nikon PTP wire, properties and session | `OpenCineNikon` | `0a309992` | |
| PTP/IP and USB-C transports (iOS) | `OpenCineNikon` | `2a473d67` | |
| Android Nikon session, JNI facade and helpers | `OpenCineNikonAndroid`, `OpenCineJNISupport` / `nikon` | `52075bc3`, `e1e9bdb9` | |
| Camera discovery (Android), cameras and pairing pages, connect wizard | `OpenCineNikon`, `OpenCineAppKit` / `nikon`, `appkit` | `099bf3d5`, `d7e6ee0c`, `4968468c`, `5dcfe36f` | |
| HDMI/UVC capture source (iOS) | `OpenCineApple` | `5b0ed62e` | |
| JPEG live-view decode into decoded-frame leases | `OpenCineApple` | `aa2dc7b4` | |
| Native frame and effects runtime (Metal presenter and scaler, decoder, Vulkan) | `OpenCineApple`, `OpenCineMedia` / `native-runtime`, `vulkan`, `media` | `8b5db25d`, `1ae9c901` | `cd18775` |
| Monitor UI and multicam for up to four Z bodies | `MonitorUI`, `OpenCineMulticam` / `monitor-ui`, `multicam` | `16c7278c`, `12081851`, `61810ae9`, `db5ae162`, `4c831d73` | |
| Monitor lifetime, common controls, shared monitor screen and capture controls | `OpenCineAppKit`, `MonitorUI` / `appkit`, `monitor-ui` | `5cb4ed1a`, `d169ff0d`, `58f1bb63`, `b8bb4751`, `0c263d9d`, `8a3fbcac` | |
| Settings (page, safety, cache, support, display, connection, assist menus and cards) | `OpenCineAppKit`, `MonitorUI` / `appkit`, `monitor-ui` | `6e28eeac`, `79b3d339`, `c989e775`, `32df76fb`, `15347d41` | `1342baa` |
| Media catalog producer | `OpenCineNikon` / `nikon` | `0be5b71e` | `490af4d` |
| Library, catalog page, filter, selection, conform preview, clip cells | `OpenCineAppKit`, `OpenCineMedia`, `MonitorUI` / `appkit`, `media`, `monitor-ui` | `966195f0`, `ef40efc9`, `2b042670`, `d90117fc`, `684a8767`, `5e6392af` | `e7d3bb1`, `55f7eed` |
| Playback model and page, playback audio | `MonitorUI`, `OpenCineApple` / `monitor-ui` | `27970cb5`, `674c83b2` | `ced835b` |
| Clip export (Apple and Android) | `OpenCineApple` / `native-runtime` | `55ec0fb4`, `47d82767` | `f818bd3`, `dc23fca`, `0f51121` |
| Frame.io workflow, delivery panels and coordination | `OpenCineFrameIO`, `OpenCineAppKit`, `MonitorUI` | `5e63cd74`, `f179073d`, `8c14f615` | `d79b371`, `435047e`, `e3ee6de` |

Stays in the app: brand, entitlements, credential storage, the Nikon-only panels composed into
the shared shell's typed slots, assist and inspector state beyond the typed adapters
(nikon.assists, partial), discovery and control maintenance, the Watch app and the Android facade.

## Not retired yet

Open or partial rows of the checkpoint ledger at this snapshot (34 of 46 checkpoints done):

| Row | State | What is left |
|---|---|---|
| pocket.integration | partial | iOS `CameraSession` and neutral compatibility owners |
| pocket.multicam, nikon.multicam | partial | Whole multiview stage composition and the simulated 2 and 4 camera exit (multicam lane) |
| pocket.compat, nikon.compat | open | Final donor retirement, compatibility inventory, duplication exit |
| insta.runtime, insta.player | partial | Android playback picture is black on the emulator (insta-black lane) |
| insta.integration, insta.compat | partial | Luna session compatibility and remaining Pocket view-core copy (insta lane) |
| nikon.assists | partial | App assist and inspector owners beyond typed adapters (nikon-assists lane) |
| finish.matrix, finish.guide | open | Final combined matrix; refresh of this inventory and the tester guide |

`insta.multicam` is not applicable (excluded from the denominator).
