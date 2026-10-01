# OpenCineCore

Portable common contracts for the OpenCine camera monitor apps: identity, observations with
provenance, capability descriptors, camera state, the command lifecycle, monitoring-entry
composition and a small camera-session seam. Manufacturer integrations translate their
protocols into these values; shared UI and multicam read them without knowing which camera is
behind them.

Status: pre-release (plan work package CORE-01). No production app depends on it yet. Expect
interface changes driven by the first real adapter slices (CORE-02).

## Products

| Product | Contents | Use from |
|---|---|---|
| `OpenCineCore` | Value types and the `CameraSession` protocol. Foundation only. | Integrations, multicam, UI presentation, apps |
| `OpenCineCoreTestSupport` | Deterministic fakes (`FakeCameraSession` in DJI-like, Nikon-like and Luna-like configurations, picture-only and control-only entries) | Test targets only; never link into an app |

Media algorithms (`OpenCineMedia`) will be a separate target in this repository.

## Import rules

- `OpenCineCore` imports only Foundation. It never imports UI, a manufacturer integration,
  Multicam or an app. Platform media types (`CVPixelBuffer`, `UIImage`, `Bitmap`, GPU textures)
  never appear in portable state.
- Shared code never chooses behavior from a manufacturer name or `IntegrationID`.
- `Tests/OpenCineCoreTests` enforces the import and brand-name rules on `Sources/OpenCineCore`.

## Model in one screen

- **Unknown is `nil`.** Every telemetry field is an `Observation` whose `value == nil` means
  unknown, never `false`, `0` or `""`. Observations carry origin (camera-reported,
  protocol-derived, image-estimated, clock-derived, operator-provided, unknown), timestamp,
  validity and optional precision. Freshness is computed against a caller-supplied `now`.
- **Capabilities have four layers:** support (in `CapabilitySnapshot`), value domain and access,
  current availability with a typed reason, and semantics (native or emulated, readback or
  acknowledgement only, qualification). Any change advances `CapabilityRevision`.
- **Settings use a reviewed sum type** (`SettingValue`) whose case implies its key: ISO ladder or
  bounded auto, shutter as native duration or native angle, aperture, exposure compensation,
  white balance, rational frame rate, focus mode, zoom. `recording` and `focusPoint` are
  command-only controls.
- **Reported state is separate from requested state.** `RecordingState` is camera-reported only.
  Command progress lives in `CommandReceipt`, tracked by `OperationID`:
  `created > admitted > sent > accepted > awaitingObservation > confirmed`, or `rejected`,
  `failed`, `timedOut`, `outcomeUnknown`.
- **Recording uses explicit start and stop.** UI toggles resolve against a fresh snapshot first.
- **Admission is shared.** `CameraSnapshot.rejection(of:at:)` checks session, connection, control
  epoch, deadline, authority and lease, capability revision, support, access, availability and
  domain. Integrations add their own protocol rules after it.
- **Monitoring entries compose roles.** `MonitorEntryDescriptor` holds an optional picture, an
  optional camera session, telemetry and control authority; at least one role must exist.
- **`CameraSession`** offers a bounded latest-value snapshot feed and reliable outcomes. Its doc
  comment specifies buffering, cancellation and close semantics.
- **`MonitorLayoutCapabilities`** is a separate ten-field layout projection matching the UI's
  current `MonitorCapabilities`, derived from the richer model where Core has vocabulary.

## Development

```sh
swift build
swift test
```

The package uses Swift 6 language mode (complete concurrency checking). Platforms: iOS 17,
macOS 13, watchOS 10.

## License

Apache License 2.0. See `LICENSE` and `NOTICE`.
