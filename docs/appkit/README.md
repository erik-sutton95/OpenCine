# OpenCineAppKit (`appkit`)

The shared app shell (SHELL-02, grown by SHELL-03): the saved-camera store, the connection model,
the cameras and pair screens, the root and monitor lifetime and the common controls, over Core's
integration contract (`CameraIntegration`, see [core](../core/README.md#integration-contract-shell-02)). Swift product `OpenCineAppKit`, Android
module `com.opencapture.opencine:appkit`.

## Boundaries

- Builds on `OpenCineCore`, `OpenCineMulticam` and the shared UI only; never an integration or an
  app. Apps list their integrations and fill the typed slots (`AppKitRules`, Kotlin
  `AppKitRulesTest`).
- Names no brand, product or app, and keeps no unlisted mutable global (the shared UI rules scan
  it: `SharedUIRulesTests`, Kotlin `SharedUIRulesTest`).

## Saved cameras

`SavedCamerasStore` keeps one `SavedCamerasDocument` (version 1, JSON, dates in epoch
milliseconds, identical bytes on both platforms) at a location the app chooses in its own
namespace, plus the legacy records it was migrated from, kept mirrored for older builds (release
flow add, migrate, remove; the mirror goes in a later release).

- `load()` does a three-way merge per legacy source (base: the record hashes stored in the
  document; theirs: the legacy records now; ours: the document). Legacy edits made by an older
  build win for the fields legacy holds; document-only fields (route ids, a learned serial, route
  titles for formats without setup names) survive; cameras removed in legacy are removed.
  A read never writes legacy.
- `save(_:)` patches the legacy records in place (changed fields only; unknown fields and
  undecodable records kept verbatim; forgotten cameras removed; new ones appended), then writes
  the document with the new merge base.
- One undecodable legacy record never empties the list.
- A document from a newer build (`version` above 1) is never written; the build runs from legacy.
- Credentials, approval identities, pairing memory, media and calibration keys are never read or
  written: saved camera ids stay the legacy record ids verbatim, so they keep working.

`BodyRecordsV0` reads and mirrors the per-body JSON array two apps keep today (routes `ap`,
`wifi`, `hotspot`; `lastSetup` -> preferred route; `modelId` kept in `extras`), with dates as
seconds since 2001 (iOS) or epoch milliseconds (Android).

## Connection model and screens

`CamerasModel` (Swift `@MainActor @Observable`, macOS 14 for host tests; Kotlin `StateFlow` on a
caller scope) holds the saved cameras, the nearby sightings per integration, at most one live
attempt per camera (progress and prompt), the last failure per camera and the pairing state.

- Discovery: with no camera live and no attempt running every integration runs `discover(.passive)`;
  the pair page asks for `.active` from the integrations that list it.
- `connect(camera, route:)`, `connect(sighting)` and `addRoute(draft, to:)` start an attempt; a newer
  attempt for the same camera cancels the older one, and events from a cancelled or replaced
  attempt are dropped. `cancel`, `sessionEnded()` (the app closed the live session),
  `perform(action, for:)` (retry and use-route run here; settings, edit-route, pair-again and
  integration actions come back as a `Request` for the app).
- A connect upserts the integration's record and calls `onConnected` with the `ConnectedCamera`.
  `forget` asks the integration to drop its per-camera data, then removes the camera; `rename` and
  `forgetRoute` edit the document. `renameRoute` changes one setup title without changing its
  identity or camera name; blank restores the generated title. A codec that owns setup titles
  declares `holdsRouteTitles`, so a name cleared by an older build stays cleared on upgrade.

`CamerasMapping` turns the model into the shared page values (`CameraListItem`, setup chips,
connect steps, failure banners, `CameraPairingPresentation`; Kotlin `CameraItem` and the `Monitor*`
values). Integration copy is shown as given; the frame copy is the shell's.

`CamerasScreen` and `PairScreen` (SwiftUI over `CamerasPage` / `PairCameraPage`, Compose over
`MonitorCameraPage` / `MonitorCameraCard` / `MonitorPairCameraPage`, including the rename and remove
dialogs) render the model. Each app entry is `AppIntegration(integration, slots)`; the typed slots
are `pairing` (pair-page content while choosing), `addRoute` (builds a `RouteDraft`) and `prompt`
(renders an `IntegrationPrompt`). Shared code never asks which integration an entry is.

Integrations with preparation wizards pass an `IntegrationPairingFlow` to `PairScreen`: the
current step's presentation, primary/back/selection actions and pane content. The shared page
still owns the rail, layout, diagnostics and help controls. This replaces the ordinary chooser
and its extra content for that render; passing `nil` (Kotlin `null`) resumes the connection
model's progress and recovery presentation. Discovery keeps the same pairing lifecycle.

Setup chips offer Rename setup even for a camera's only route. The cameras and pair pages accept
optional `onPrivacy` and `onTerms` actions; `ShellActions.privacy` and `.terms` forward them through
`AppShell`. Apps keep their existing URLs or in-app legal documents. These actions do not alter
connection state or own discovery.

Review fixtures: `ReviewScreens` (iOS simulator only) renders camera, pairing and shell states,
including legal links and a named single setup in phone and tablet orientations. It writes PNGs when
`OPENCINE_SCREENSHOTS` is set (`TEST_RUNNER_OPENCINE_SCREENSHOTS=<dir> xcodebuild test -scheme
OpenCine-Package -destination <private simulator> -only-testing:OpenCineAppKitTests`).

## Shell: root, monitor lifetime and common controls (SHELL-03)

`ShellModel` is the app's root state over `CamerasModel`: the route (`cameras`, `pair`,
`monitor`), an optional cover (`settings`, `media`), the operator's pairing request and the camera
on the monitor. It takes over `CamerasModel.onConnected`: each successful connect presents its
`ConnectedCamera` and this shell owns its session.

- `present(camera)` shows a session this shell owns; `borrow(camera, release:)` shows one another
  owner lends (a multicam member). A newer camera replaces the monitor: the old owned session
  closes as `.replaced`; a borrowed one is handed back with its `release`.
- `close()` leaves the monitor once: presentation and editors retire, an owned session closes
  (`.requested`, never a camera command, so a recording keeps going), a borrowed one is
  returned (never closed). Discovery resumes through `CamerasModel.sessionEnded()`.
- The session reporting `.disconnected` by itself leaves the monitor without a second close.
  `.recovering` keeps it: transport recovery is the integration's, and the last reported values
  stay shown.
- Covers never disconnect. A connect starts uncovered.
- Presenting the monitor's current session again is idempotent: it preserves the host, cover,
  editors and ownership, including a borrowed session. A delayed connect callback cannot close it.
- `setSceneActive(_:)` takes every OS signal (scene phase, app notifications, Android lifecycle)
  and calls `onSceneActivity` once per change.

`MonitorControlModel` (`shell.control`) holds the one snapshot subscription of the monitor's
session and the operator's common controls: `shown(key)` (a pending target over the report,
never written into the snapshot), `set(value, label:)` (coalesced per setting for 120 ms, latest
wins, then one `CameraCommand` against the snapshot of that moment), `record(start:)` (an
explicit start or stop resolved from a fresh report; unknown sends nothing), `edit(key)` /
`isCurrent` / `commit` (an editor is obsolete once the session, control epoch, authority or the
setting's domain changes) and `isRecording` (`nil` while unknown, never idle). `unbind()` retires
everything in flight: a late receipt, snapshot or record outcome never reaches the next camera.
Operator copy for outcomes is `note(for:_:)`; apps route notes, the media refresh after a stop
and, while their views still read an app status type, a projection (`onChange`).

`cancelEdit(key)` retires only that setting's pending target and captured editors. A native
gesture can take over without changing the session epoch or invalidating unrelated settings.
The old coalescing wake cannot send a younger successor early, and an already-sent command's
receipt cannot clear that successor. Camera reports remain authoritative; cancellation sends
no command and does not undo admitted camera work.

`AppShell` (SwiftUI; Compose `AppShell`) renders the root from a `ShellModel`, a `ShellBrand`
(name, nearby note), `ShellActions` (diagnostics, problem report, watch feed, multiview,
integration actions) and two slots: `monitor` (keyed by the monitor lifetime, so covers and
rotations never create a second host; `hostsMounted`/`hostsUnmounted` count them) and `page`
(cover pages over the cameras and pair pages). Until an app's monitor moves into the shell
(SHELL-03 I-2 and later), its existing native monitor is the `monitor` slot and draws the cover
pages over itself.

## Monitor composition and capture

`MonitorScreen` owns the stable picture/assist host positions and the common status, power,
capture and system regions from `FieldMonitorLayout` (Compose `MonitorFieldLayout`). Its
`MonitorScreenPresentation` carries operator visibility, lock, coverage and popup state rather
than camera telemetry. Native tools, detail panels, cover pages and recovery content have fixed
slots; they cannot replace the picture host. Covers sit above panels and controls. A capture
panel raises the system layer so Record and DISP keep receiving their actual gestures.
Transient panels may retain dimmed chrome underneath while blocking its input and accessibility.

Swift uses `MonitorCanvas` to frame the picture and assists in the source picture well. Compose
keeps the native picture slot at the full viewport because the Vulkan renderer owns a full-screen
surface; a GLES adapter can frame its own picture well. Both retain the same native hosts through
rotation and coverage. `MonitorCanvas` remains available to consumers that have not migrated.

`MonitorStatusChrome` composes the portrait and landscape recording/timecode readouts and narrow
storage, format, color, mode and link slots. `control.statusPresentation(elapsedSeconds:)` projects
optional Core recording/timecode and optionally supplied camera elapsed telemetry; unknown
recording suppresses a compatibility timer's default zero. Presentation creates no timer.
`MonitorSystemControls` owns bounded lock, settings, media, capture and display positions. Its
visibility policy keeps Lock when locked, capture/settings while recording, and hides media for
a borrowed session. Native return and operator edit decorations stay in the control builders.

`control.captureField(key)` projects ISO, shutter, white-balance, exposure-compensation and focus descriptors into typed
`MonitorCaptureChoice` detents and an immutable editor. Missing reports have no selection, even
when the drum visually centers a legal option. `MonitorCaptureReadout` (Compose
`field.quickControl()`) and `MonitorCaptureDrum` preserve that editor through hold/drag/release and
persistent panels. `commit` checks readiness, writable access, availability, authority, domain,
epoch and binding again after the coalescing window. No queued stale editor writes to a replacement
camera. White-balance Kelvin ranges use the declared step, or 100 K for a continuous domain,
with bounded allocation; other setting ranges are not guessed.

`MonitorCaptureButton` owns common video confirmation and recording actions; only photo capture
and the integration's shooting-mode editor are slots. Optional `recordEditor`/`commitRecord`
authorize the state actually shown by a confirmation. An epoch, authority, mode, binding or
recording change retires that approval. Existing explicit `record(start:)` preserves idempotent
targets; `recordAndWait(start:)` shares its admission/pending gate and returns the actual terminal
receipt only while the binding remains current.

## Operator preferences

`MonitorOperatorPreferences` stores common awake, HDR display, record confirmation, haptic
and original-cache choices. The app supplies its existing UserDefaults domain or Android
SharedPreferences file and keys. Reads do not write missing defaults or rewrite the optional
legacy awake key; explicit false survives reload, and a current awake value wins over legacy.
Apps with an existing structured preferences document can bind its values directly to the
shared settings views instead of changing that document's storage format.

## Tests

| Swift (`Tests/OpenCineAppKitTests`) | Kotlin (`Android/appkit/src/test`) |
|---|---|
| `Migration` (upgrade, idempotence, mirror round trip with the old decoder, downgrade then upgrade, bad record, future version, empty) on `Fixtures/saved-cameras/body-records-v0-*.json`, both date flavors | `MigrationTest`, same method names |
| `Document.theDocumentFormatIsShared` (`Fixtures/saved-cameras/document-v1.json`, byte for byte) | `DocumentTest`, same name |
| `AppKitRules.appKitImportsNoIntegrationOrApp` | `AppKitRulesTest`, same name |
| `CamerasModelTests` (passive on cameras, active on pair, discovery stops while attempting or live, one attempt per camera, cancel, failure actions, prompts, upsert on connect, forget calls the integration, rename and forget a route) | `CamerasModelTest`, same method names |
| `CamerasMappingTests` (golden cards, nearby, pair page, route titles) | `CamerasMappingTest`, same values |
| `ReviewScreens.reviewFixturesRender` (iOS only) | not ported (Compose has no host renderer here) |
| `ShellModelTests` (routes, connect A then replace with B and deliver A late, close once, disconnect during a pending edit, close while recording sends no stop, cover and reveal keep the host and connection, link loss keeps the held picture, stale record receipt, borrow and return, scene activity once per change) | `ShellModelTest`, same method names |
| `MonitorControlModelTests` (pending over the report, coalescing, record unknown stays unknown, record from a fresh report, domain or authority change obsoletes the editor, a retired binding drops late outcomes, notes) | `MonitorControlModelTest`, same method names |
| `ReviewScreens.reviewRootAndCoverFixturesRender` (iOS only: cameras, cover, pair, monitor slot, cover over it, revealed, closed) | not ported |

Kotlin differences: JSON is org.json from android.jar (the real artifact backs the JVM tests);
`StoredString` (`SharedPreferences.stored(key)`) replaces `StoredData`
(`StoredData.userDefaults(key:)`); the store and the model are confined to one thread instead of
the main actor; the model's `State` is one `StateFlow` value and `forget` suspends; slots are
`@Composable` lambdas (Swift: closures returning `AnyView`). The shell's Kotlin models publish
one `StateFlow` `State` each (`ShellModel.state`, `MonitorControlModel.state`) on a caller scope;
Compose `AppShell` takes a `pageFrame` (the app's insets and back handling around the cameras and
pair pages) where SwiftUI takes a `safeArea` function, and the Compose cameras page has no watch
feed entry yet (only `PairScreen` takes `ShellActions.watchFeed`).
