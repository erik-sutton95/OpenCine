# OpenCineAppKit (`appkit`)

The shared app shell (SHELL-02, grown by SHELL-03): the saved-camera store, the connection model
and the cameras and pair screens, over Core's integration contract (`CameraIntegration`, see
[core](../core/README.md#integration-contract-shell-02)). Swift product `OpenCineAppKit`, Android
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
  titles) survive; cameras removed in legacy are removed. A read never writes legacy.
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
  `forgetRoute` edit the document.

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

Review fixtures: `ReviewScreens` (iOS simulator only) renders eight states and writes PNGs when
`OPENCINE_SCREENSHOTS` is set (`TEST_RUNNER_OPENCINE_SCREENSHOTS=<dir> xcodebuild test -scheme
OpenCine-Package -destination <private simulator> -only-testing:OpenCineAppKitTests`).

## Tests

| Swift (`Tests/OpenCineAppKitTests`) | Kotlin (`Android/appkit/src/test`) |
|---|---|
| `Migration` (upgrade, idempotence, mirror round trip with the old decoder, downgrade then upgrade, bad record, future version, empty) on `Fixtures/saved-cameras/body-records-v0-*.json`, both date flavors | `MigrationTest`, same method names |
| `Document.theDocumentFormatIsShared` (`Fixtures/saved-cameras/document-v1.json`, byte for byte) | `DocumentTest`, same name |
| `AppKitRules.appKitImportsNoIntegrationOrApp` | `AppKitRulesTest`, same name |
| `CamerasModelTests` (passive on cameras, active on pair, discovery stops while attempting or live, one attempt per camera, cancel, failure actions, prompts, upsert on connect, forget calls the integration, rename and forget a route) | `CamerasModelTest`, same method names |
| `CamerasMappingTests` (golden cards, nearby, pair page, route titles) | `CamerasMappingTest`, same values |
| `ReviewScreens.reviewFixturesRender` (iOS only) | not ported (Compose has no host renderer here) |

Kotlin differences: JSON is org.json from android.jar (the real artifact backs the JVM tests);
`StoredString` (`SharedPreferences.stored(key)`) replaces `StoredData`
(`StoredData.userDefaults(key:)`); the store and the model are confined to one thread instead of
the main actor; the model's `State` is one `StateFlow` value and `forget` suspends; slots are
`@Composable` lambdas (Swift: closures returning `AnyView`).
