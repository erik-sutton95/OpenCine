# Retired app owners (thin-app migration)

Which actual app implementations now use shared OpenCine owners, what remains in the apps, and
how much source each repository carries. Companion of [COMPATIBILITY-INVENTORY.md](COMPATIBILITY-INVENTORY.md)
and [TESTER-GUIDE.md](TESTER-GUIDE.md).

Updated 2026-10-10. Current product source is SDK `9a909df`, Pocket `3c753de6`, Insta
`d1b8b8a5` and Nikon `4460a435`; a later docs-only commit changes these three tester documents.

Status at the 2026-10-10 checkpoint: locally committed candidate. All three apps and
generated apps use the same capability-driven live and settings composition on each platform.
Pocket remains the common UI reference. Safe areas, camera pages, popups, capture headers,
circular focus reset and View Assist labels have shared owners; integration slots carry actual
hardware controls. Full expanded tool names use two lines; compact favorites keep their size.
Common false color offers CineStop, Video, IRE and Limits with LOG/709 reads. Shared scope,
peaking and two-axis mirror behavior retain native ownership and deployed preference keys.

The earlier exact twenty-gate matrix `275f8e15` retains its recorded source scope. The final
label delta passed eleven scoped gates (`e5f18775`): 3,156 Swift Testing cases in 375 suites and
177 XCTest cases, strict concurrency, 2,259 Android cases with zero failures and two known Core
skips, both iOS simulator architectures, three signed iOS builds for testing and all three full
Android consumers. Current app Android XML totals are Pocket 234, Insta 207 and Nikon 902,
with zero failures, errors or skips. Consumer staging, lint, debug/release and instrumentation
compilation passed; Nikon also passed its Wear/native packaging checks. Nine strict signatures,
six iPad profiles and four Pocket/Insta APK/JNI bindings passed. Compilation is not device proof.
The separate opt-in cleanup driver `9a909df` passed its Nikon signed build and source review;
its hardware restoration has not passed. It changes no shipping source or native admission rule.

Recorded Pocket/Luna original full camera workflows passed (`1946de9e` / `801a7c65`) at their
bound products. Luna's exact new clip belongs to SD bank 3 and is absent from internal bank 2
(`2787fbe1`); transfer and capture destination are not inferred. Pocket's receive/decoder fault
scenarios passed within their injected scope; the initiating Sentry dropout cause remains unknown.
Eleven optional generation-owned ingress diagnostics are implemented for future diagnosis.

Nikon's whole camera workflow remains failed/incomplete. Current native connection, complete
projected catalogue, ISO change/restoration and narrow layout observations retain their scope.
Initial label products passed native iPad portrait/landscape expand/collapse checks. The current
options run reached all eight false-color/read combinations, four mirror combinations and both
landscapes but failed final restoration, so the testcase is RED. Captured local mirror settings
still require restoration; later attempts stopped before preference changes because the camera
was not found. iPad automation worked without pending approval at the last readiness observation.
Background recovery, confirmed recording, exact new-clip playback/reopen and saved relaunch still
need a closed current Nikon proof. Android hardware, Dynamic Island phone edges, real two/four
camera operation, device performance and unexecuted special states remain untested.

Source ownership and official current duplication are bound by `b9c99891`, its legacy-glass
follow-up `b218c210`, and committed measurement `1819853f`. SDK/app matches include preserved
test oracles and bounded native/compatibility adapters; decreased totals do not mean zero copies.
The coding ledger counts adopted owners with scoped automated checks; physical qualification,
canonical integration and publication are separate. Pins, remotes and publication are unchanged.
Pocket/Insta exploratory UI-test edits remain preserved and excluded from commits. Existing
reference/accessibility/decoder skips and Nikon formatting/privacy-fixture failures retain their
recorded exclusions. Historical tables and every original checklist below retain their scope and
acceptance criteria.

## Current source ownership

These are adopted owners, rather than interfaces awaiting an app caller. Capture identifiers name
immutable coordinator source packets; they are evidence references, not Git commits. Later finite
compiler and reentry corrections remain separately captured. Original tests and pixel/native
oracles remain qualification inputs.

| Retired app owner or recipe | Shared owner and actual adapters | Frozen source evidence | State |
|---|---|---|---|
| Pocket/Insta model-name control policy, duplicated labels/lists, invented unknown FORMAT and unsupported audio pages | CameraVocabulary capture/label/LUT profiles and CameraControls; DJI and Luna supply their own values and optional services through actual Swift/Kotlin control hosts | `wave-2-source-boundary`, `wave-2-inference-and-declaration-correction`; integration compatibility corrections separate | Implemented; combined shared checks passed; actual camera behavior untested |
| Insta countdown, pause/resume, looping and streamed programmed-move lifecycle | Motion timeline/session in Swift, mirrored pure Core motion and AppKit coroutine session in Kotlin; `CameraSessionControls.swift` and `session/PocketCameraSession.kt` retain bounded Luna angle/zoom/wire adapters | `wave-3-motion-full-source-capture`, `wave-3-motion-predicate-reentry-source-capture` | Implemented; recorded manual-clock red/green and shared checks passed; native/physical motion qualification separate |
| Pocket media acquisition, download scheduling and return-to-live authority; duplicate progressive cache policy | Existing Library host IO, Media return session, cache and progressive reader/writer; `CameraMedia.swift`, `MediaLibraryController.kt` and Nikon identity/storage adapters retain actual addresses and source services | `wave-3-media-scheduling-source-capture`, `wave-3-progressive-cache-source-capture` | Implemented; shared IO/lifetime checks passed; camera transfer/recovery qualification separate |
| App-packed false-color lattice and common color/transfer math | Media `MonitorFalseColorLattice` and typed source color values; actual P/I JNI facades and Pocket look baking delegate; Nikon retains its calibration facts | `wave-2-source-boundary`, `wave-5-transfer-inference-source-capture` | Implemented; positive golden fixtures retained; shared checks passed; actual native/physical effects separate |
| P/I and Nikon catalog/filter/calendar/selection/delete page recipes | AppKit Library/Gallery/Deletion and CameraControls `MonitorOperatorCatalogScreen`; actual `MediaLibraryStub`/`MediaLibraryScreen` and Nikon `MediaBrowser`/`MediaBrowseScreen` supply records, access, storage and native thumbnails | `wave-4-production-catalog-source-capture`, `wave-5-complete-nikon-catalog-source-capture`, accepted-deletion follow-ups | Implemented; current shared checks passed; current complete consumer flows remain to bind |
| Copied photo page/loading/variant/rating/filmstrip recipes | Existing Picture/Gallery owners and `MonitorOperatorPhotoScreen`; original/thumbnail IO stays on Library with captured bounded source ports; native decoding is an app leaf | `wave-5-production-photo-owner-source-capture`, `wave-5-original-image-io-owner-source-capture`, `wave-5-complete-nikon-photo-source-capture24`, `wave-4-raw-thumbnail-owner-source-capture` | Implemented; current shared checks passed; native decoder/consumer/physical scopes separate |
| P/I and Nikon player preparation, adjacent-item, controls, effects/scopes, audio and action lifetime recipes | AppKit `MonitorOperatorMediaModel`/Playback/Scope owners, CameraControls `MonitorOperatorPlaybackScreen`, Apple native assist/audio and Android native sampling; actual P/I `MediaPlayer`/`MediaPlaybackScreens` and Nikon `MediaBrowser`/`MediaPlaybackScreen` keep real native picture/source ports | `wave-5-full-playback-source-capture`, `wave-5-complete-nikon-ios-player-source-capture28`, later Nikon Kotlin/cleanup captures, `wave-6c-rating-predicate-reentry-source-capture4` | Implemented; combined shared and scoped native checks passed; complete app/device flows separate |
| P/I and Nikon delivery page/preparation/batch/consent/cancel recipes and copied Photos helper | Existing Delivery/Library and FrameIO owners, common delivery screen and AppKitApple Photos adapter; real native export, credentials, route/hop and provider content remain bounded app ports | `wave-5-delivery-owner-source-capture`, neutral naming follow-up, `wave-6b1-delivery-contract-source-capture15` and subsequent native/adopted-lease captures | Implemented; current shared checks passed; actual destinations and physical route/export flows untested |
| Copied watcher connection, reconnect/framing/freshness/control timeout and complete P/I screen/tool assembly | One RelayAppleClient transport/clock with typed watcher policy; Relay watcher values, AppKitApple `MonitorWatcherSource`, CameraControls `MonitorOperatorWatcherScreen`; P/I clients are native/color factories. Nikon Android uses common watcher overlay; no absent P/I Android feature was added | `wave-6-complete-watcher-source-capture22`, tap captures and finite wiring/compile corrections | Implemented; shared policy/tap tests passed; current app transport/native/physical qualification separate |
| Wrist transport/control/publication and broadcaster/nearby composition copies | Existing Relay/Watch and Apple/Android runtime owners; app aliases preserve distinct deployed monitor/watch schemas, native frames and captured command receipts | `wave-3-apple-watch-runtime-source-capture`, Android wrist/socket captures, `wave-4-unified-apple-relay-host-source-capture`, `wave-5-android-broadcaster-owner-source-capture` | Implemented; recorded shared/native checks passed; actual paired wrist/network hardware untested |
| P/I native backdrop queue/cache/look/raster producer and duplicated visible lifecycle | Apple raster producer, Media immutable mirrored values, AppKitApple visible owner; all actual live/watch/multiview/playback builders capture source/item identity and epochs. Android uses existing NativeBackdropFeed/NativeGlBackend | Backdrop packet `57503cfb`; command-admission and backdrop predicate corrections retained separately | Implemented; eight native backdrop/pixel cases passed; current app/GPU/physical gates separate |
| P/I inspector and multiview preview polling/assembly | One AppKitApple image-preview session over the existing renderer, common inspector preview UI and mirrored generic meaning/Compose display; actual P/I and multiview adapters supply native facts and truthful optional audio | `wave-6-inspector-preview-source-capture10` plus exact Multiview fragment and two finite corrections | Implemented; 14 controlled native preview cases passed; original renderer/sample/pixel guards retained; physical preview untested |
| P/I and Nikon live chrome/readouts/popup/scopes/inspector/editor plus root covers and settings recipes | One `MonitorOperatorLiveBody` and common settings body per platform serve Pocket, Insta, Nikon and generated apps. Shared owners control safe area, camera page, capture header, popups, scope/assist chrome and circular focus reset; typed native slots carry hardware controls only. Nikon retains descriptor facts, three DISP modes and photography features | Local SDK shipping labels `88899de` / P `3c753de6` / I `d1b8b8a5` / N `4460a435`; current owner audit `b9c99891`, final label gates `e5f18775`, earlier matrix `275f8e15` | Implemented; current automated consumer gates passed; physical scopes and remaining Nikon/platform checks are stated above |
| Nikon Settings count/clear, account consent/rehost/error and stale peer grant/decline policy | Existing Cache/Account owners and common cards; captured native IO/hop cleanup remains in bounded adapters. Pending request receipts include source, peer and request revision | Swift/K cache observation captures, settings/request capture, `wave-6c-settings-cover-pointer-source-capture1` | Implemented; current shared checks passed; actual OAuth/network/cache and cover interaction untested |

The common owner tables do not retire integrations' hardware behavior. DJI/Luna/Nikon protocol,
raw controls, native frame acquisition, discovery/admission, storage keys, credentials, native
export and platform permission leaves remain in their declared layer. Compatibility facades and
remaining copied bodies are listed in the companion inventory, including the newly delegated Nikon FPS
sampler and its recorded scoped consumer qualification. Large app files still include these adapters; a shared entry alone is not proof that an
entire file became thin.

## Current production counts, 2026-10-10

Census `5e3f1569` binds current committed source paths and SHA256 values with the same original
extensions, exclusions and all-text-line definition. It includes nonexcluded SDK developer,
harness and support sources; it is not installed size, interface quality or hardware proof.

| Repository | October 5 integration snapshot | Current source | Change |
|---|---:|---:|---:|
| OpenPocketCine | 87,486 lines / 341 files | 35,455 lines / 197 files | -52,031 lines |
| OpenInstaCine | 87,141 lines / 366 files | 23,209 lines / 178 files | -63,932 lines |
| OpenZCine | 139,327 lines / 292 files | 99,449 lines / 271 files | -39,878 lines |
| Three apps | 313,954 lines / 999 files | 158,113 lines / 646 files | -155,841 lines |
| OpenCine | 181,063 lines / 829 files | 272,436 lines / 1,310 files | +91,373 lines |
| Everything | 495,017 lines / 1,828 files | 430,549 lines / 1,956 files | -64,468 lines |

This compares the October 5 integration snapshot, not each app's main branch. The official
normalized duplicate-pair measurement is in [COMPATIBILITY-INVENTORY.md](COMPATIBILITY-INVENTORY.md#current-normalized-duplication-2026-10-10).

## Historical production counts: October 8 candidate WIP

Counted 2026-10-07 23:52 UTC (2026-10-08 locally), from the coordinator's current four-repository
path enumeration `62dd1213` and a byte-hash/line inventory `8bc6e9fb`. Same extensions, path
exclusions and all-text-line counting as the dated method below. Present tracked files plus
nonignored new production inputs are included; deleted tracked paths are absent. No source
changed during this count. This is a source-only WIP measurement, not a committed or final
qualification snapshot. The coordinator must bind or refresh it after all candidate inputs settle.

| Repository | October 5 integration snapshot | Current candidate WIP | Change from that snapshot |
|---|---:|---:|---:|
| OpenPocketCine | 87,486 lines, 341 files | 35,468 lines, 197 files | -52,018 lines |
| OpenInstaCine | 87,141 lines, 366 files | 23,191 lines, 178 files | -63,950 lines |
| OpenZCine | 139,327 lines, 292 files | 98,382 lines, 271 files | -40,945 lines |
| Three apps | 313,954 lines, 999 files | 157,041 lines, 646 files | -156,913 lines |
| OpenCine | 181,063 lines, 829 files | 269,582 lines, 1,297 files | +88,519 lines |
| Everything | 495,017 lines, 1,828 files | 426,623 lines, 1,943 files | -68,394 lines; +115 files |

| App | Current directory | Lines | Files |
|---|---|---:|---:|
| Pocket | `Apps/Android` | 13,614 | 82 |
| Pocket | `ios/OpenPocketCine` | 21,450 | 104 |
| Pocket | `Sources/OpenPocketViewCore` | 76 | 6 |
| Pocket | `Sources/OpenPocketCineAndroidFacade` | 315 | 4 |
| Insta | `Apps/Android` | 9,037 | 82 |
| Insta | `ios/OpenInstaCine` | 13,632 | 84 |
| Insta | `Sources/OpenInstaViewCore` | 197 | 7 |
| Insta | `Sources/OpenInstaCineAndroidFacade` | 312 | 4 |
| Nikon | `Apps/Android` | 51,071 | 169 |
| Nikon | `ios/Runner` | 37,830 | 68 |
| Nikon | `Sources/OpenZCineCore` | 7,821 | 24 |
| Nikon | `Sources/OpenZCineAndroidFacade` | 1,548 | 7 |

The metric deliberately preserves the old path definition. It therefore also counts developer
harness/test-support source under nonexcluded `Sources/` paths; it is not an installed-binary
size or a measure of interface quality. Shared source/file growth must be assessed alongside the
app reduction. The scoped preview retirement was 750 to 747 production lines (app 750 to 235;
512 shared), and the Nikon Compose live/settings scope grew by 228 lines overall (app -804,
shared +1,032). Those moves retired copied policy owners but did not produce large net reductions.

## Qualification and final revision binding

Current October 10 commits and checks are stated above. The following table and candidate
counts preserve the October 8 verification fence and do not qualify later physical flows.

### Historical verification, 2026-10-08

Evidence inspected for this update is limited to immutable source/consumer receipts and current
call sites. The documentation lane ran no compiler, build, Git operation or device check.

| Gate | Recorded scope at this documentation fence |
|---|---|
| Shared portable Swift | `final-sdk-swift-test-v2`: 3,132 Swift Testing cases in 372 suites and 176 XCTest cases passed, log `65d8c035`; `final-sdk-swift-strict-v2` passed, log `926cf3e4`. Both fully reaped with all 1,290 guards exact after current private immutable progress callback capture. Optimized shipping Release v3 passed, log `63035e04`, both simulator architectures/all 1,296 guards; compile-only |
| Shared Android | `wave-6c-shared-android-all-v24`: test/lint/release passed; 2,221 executions, zero failures/errors, two known Core skips; 343 raw XML files |
| Actual portable consumers | Pocket v3: 76/13; Insta v2: 60/11; Nikon v1: 404/23 tests/suites passed, each with its strict receipt and exact raw log |
| Native shared preview/backdrop | 14 controlled preview cases and eight backdrop cases, including the two original pixel oracles, passed on the recorded private simulator; simulated/native scope, not hardware |
| Actual Pocket native/Android | Native v4: 580 cases, 579 passed, one original no-tree accessibility skip, zero failures; arm64/x86_64 products. Android v6: 233 cases/44 raw XML, zero failures/errors/skips; full consumer compilation/lint/staging and repository v2 passed. APK/JNI packet `321e6b68` passed |
| Actual Insta native/Android | Native v13: 403 cases, 402 passed, one original accessibility-service skip, zero failures; arm64/x86_64 products. Android v8: 207 cases/40 raw XML, zero failures/errors/skips; full consumer compilation/lint/staging passed. Current APK/JNI/assets packet `dc7fa7d9` passed |
| Actual Insta original playback input | Whole decoded-movie v4, native metadata v2 and pointer-cancel v1 passed on retained emulator5712 with original fixtures/assertions. SIMULATED catalogue/ports; eventual B pixels do not qualify injected transient old-A buffers or a real camera |
| Actual Nikon native/Android | Android v5: 897 cases/114 raw XML, zero failures/errors/skips. Original real-service AX/action/pixel six v2: six passed, zero failure/skip. Native v15: 390 cases, 388 passed, zero failures, two known skips; arm64/x86_64 products. Full native14 reserve interruption is retained separately, not a test pass |
| Original Pocket installed Android/GPU | Original native matrix v1: 21 passed (two-control/four-owner, four synthetic Surface picture/identity, chrome geometry/actions, native metadata/prepare). Original GPU v1: one test/27 comparisons passed. SIMULATED observations/pixels; real GPU/camera/HEVC/peer performance untested |
| Original installed/template flows | Original Pocket iOS MultiviewUIFlowTests passed five/zero failure/skip on existing default3/explicit4/one-capability inputs. Focused original AX v1/v2 each retain 0 passed/0 failed/1 no-tree skip; v2 scene registration/restoration changes only two setup fragments, with original fourteen XCTest sites/body/walker/waits/skip preserved and VoiceOver assertions untested. No product fix or VoiceOver pass is inferred; generated full v3 passed all original eight contracts plus three installed cases on each platform, zero failure/skip: Android summary `b803fe6b`/log `ed85bea0`, iOS summary `ed42ab03`/log `bb0f0a99`, combined receipt `b9843798`. Both retained all 1,356 source guards; iOS built camera/SIMULATED Debug/Release products and restored private077 Shutdown with no other device state changes. Camera data remains SIMULATED; native decoding and installed operator/lifetime/persistence/isolation checks passed. No new two-decoded-picture selector required |
| Final exact source/artifact binding | Current Nikon APK/AAB/staging/DEX/JNI v5 passed, packet `5a13191a`: debug99/release81 production native DEX methods, 18 unused Vulkan declarations pruned by unchanged R8, all99 production exports retained. Original native fixture exports remain separate and exact. Latest shared iOS palette is qualified in Nikon native v15; final four-repository content/commit and exact combined matrix/dupes binding recorded in first-pass candidate `f6f1ed71` and matrix `7004c896`; final status-only documentation is rebound separately |
| Physical qualification | Untested for the current combined migration on all three brands/platforms. Xcode reports the iPhone locked again and the original selected test awaits unlock; Android remains detached. Earlier unlocked readiness and standby/navigation results do not establish a current combined pass |
| Pins/integration/release | Unchanged by this documentation checkpoint; no final closure claimed |

The table keeps earlier Working HEADs as provenance and binds the local commits through product
source receipt `78c7b5e0`, index/content manifest `db39cbd8`, docs-only receipt `61d94052` and
first-pass matrix `7004c896`. All runs retain their original input scopes. Later delivery/source
corrections and the docs-only head remain explicit; no old app guard map is restamped.
Pocket/Insta exploratory UI files remain preserved outside their registration-only committed
candidates (`9ed86a6c`/`70bff1f8` working; `f1ec6039`/`b4f4c22b` committed).

| Repository | Working HEAD at enumeration (provenance only) | Final candidate revision/content manifest | Actual consumer/native gates | Physical result |
|---|---|---|---|---|
| OpenCine | `7a0d073150c181cad702ca1b3b749e6bb5ed37bd` | Product `e5a804d37fa70e97228954988a4c8cd0d06a3c81`; docs-only first-pass candidate `ecf912c442039c64d54301fb9977f47a7a77463e`; matrix `7004c896` | Recorded shared gates above; latest palette in Nikon native v15; exact combined binding pending | Untested |
| OpenPocketCine | `55465f8a9b3a68a7663eb35fbb44869cfd4c5694` | Local adopter `524facaefc70a413180ca9d516f681fe36f51d2c`; exact final combination matrix `7004c896` and candidate `f6f1ed71`, with recorded input scopes and finite later deltas retained | Portable76, native580/one skip, Android233, repository/linkage, original Android21/GPU27 and iOS Multiview5 passed; original AX remains a known no-tree skip with VoiceOver assertions untested; final binding pending | Untested |
| OpenInstaCine | `e5e6e5e5897b7254459d2aa666d4ca0b2071dbb7` | Local adopter `f2a830e3cd921c72e1deb94a9dcf06442c8b38fe`; exact final combination matrix `7004c896` and candidate `f6f1ed71`, with recorded input scopes and finite later deltas retained | Portable60, native403/one skip, Android207, original whole movie/metadata/cancel and linkage passed; exact combined binding pending | Untested |
| OpenZCine | `61fc7109f9a3fc699d5f97f0f174bef17de1b55a` | Local adopter `8cfe698378cc7673a5fca8c8383f868d4d995d42`; exact final combination matrix `7004c896` and candidate `f6f1ed71`, with recorded input scopes and finite later deltas retained | Portable404, native390/two skips, Android897 and original six native action/pixel cases passed; APK/AAB/JNI v5 passed; final binding pending | Untested |

Candidate first-pass receipt `f6f1ed71` binds all four local repositories and six pairs,
`missing={}`, no growth against unchanged baseline `3ee29c52`; SDK measured text equals its
committed inputs under the existing newline handling. These duplicate-block lines are distinct
from the dated WIP all-text production-line census, which has not been recounted.

| Pair | Existing baseline | Local candidate first pass | Change |
|---|---:|---:|---:|
| OpenCine / OpenInstaCine | 19,214 | 706 | -18,508 |
| OpenCine / OpenPocketCine | 2,505 | 256 | -2,249 |
| OpenCine / OpenZCine | 672 | 434 | -238 |
| OpenInstaCine / OpenPocketCine | 55,295 | 9,934 | -45,361 |
| OpenInstaCine / OpenZCine | 716 | 584 | -132 |
| OpenPocketCine / OpenZCine | 1,687 | 621 | -1,066 |

Final Atlas unit v1 passed 102 cases with zero failures/skips (`6d015007`), and plain check passed.
The separate registered-ref `atlas check --sources` failed with 32 old authored-ref errors;
that failure is not the successful local candidate result. Authored refs, pins and baseline
were unchanged. Root records a fresh v2 candidate after the final status-only docs commit.

## Remaining completion criteria

The current ledger is 44 of 46 (96%). Nikon compatibility and final matrix exits are reopened
for current real-camera controls, landscape containment and the complete original physical
flows. All six current consumer gates, both source reviews and generated default-15 acceptance
passed; no current full physical flow has completed. Integration, pin moves and publication
remain separate and require explicit authorization.

### Historical closure, 2026-10-08

The fixed original ledger has 47 registered IDs and 46 eligible IDs, with unsupported Insta
multicam still excluded. Root closed `finish.template` against both original eleven-case
platform passes (`b9843798`) and the original Pocket/Insta compatibility exits against
`2415a4b7`. Final matrix and documentation-head closure is recorded in the coordinator handoffs
and `CODEX-RESUME-20261007/final-current-head-matrix-v2/receipt.json`. Physical qualification,
pins, integration and publication remain separate; no denominator or acceptance criterion changed.

The earlier Insta Android black-picture blocker remains resolved within its recorded emulator
scope (two media-owner input, ten movie rendering and three backdrop cases on each of two runs).
That historical success is neither reopened by this documentation update nor expanded into
physical/current full-flow qualification.

## Historical revision snapshot: 2026-10-05

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

## Historical production counts: 2026-10-05

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

## Historical committed owner provenance

The following existing commit tables are retained as migration provenance. Their commits are
not newly assigned final candidate revisions, and a historical ownership row does not qualify
later app adapter or lifetime changes.

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
