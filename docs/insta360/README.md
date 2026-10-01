# OpenCineInsta360

The Insta360 Luna integration for OpenCine apps: wire protocol, Apple I/O adapter and the
OpenCineCore `CameraSession` for Luna. Extracted from OpenInstaCine (VENDOR-03).

## Products

| Product | What it holds | Imports |
|---|---|---|
| `Insta360Protocol` | UCD2 framing, protobuf, Luna requests/status/schema tables, gimbal pose, screen wire. Pure Foundation, builds and tests on macOS. | Foundation |
| `Insta360Apple` | `LunaCameraBackend` (BLE consent, encrypted Wi-Fi credential handoff, camera Wi-Fi join, TCP 6666 control and HEVC preview, media), `LunaCameraSession` (`OpenCineCore.CameraSession`: ISO, shutter, white balance, record with readback confirmation), the `CameraBackend` discovery/connection/picture/media seam, `LunaIntegrationConfiguration`. | Insta360Protocol, CKcp, OpenCineCore, Apple frameworks |
| `Insta360AppleTestSupport` | `FakeLuna`, a scripted camera behind a session's link. Test targets only. | Insta360Apple |

`CKcp` (internal C target) is KCP plus two shims (`luna_kcp_*`, `luna_add_ipv4_alias`).

## Using it

```swift
let backend = LunaCameraBackend(configuration: .init(
    keychainService: "org.example.mycine.camera", appName: "MyCine", logPrefix: "MyCine"))
let session = backend.openSession()   // one OpenCineCore session per connection
```

Every instance owns its own link, session, credentials store and callbacks; nothing is
process-wide except the phone's single camera access point (192.168.42.x, `LunaWiFi`), a
qualification limit: two simultaneous Luna connections are unsupported.

`LunaIntegrationConfiguration.keychainService` defaults to `org.opencine.openinstacine.camera`
so OpenInstaCine's saved authorization identity and camera Wi-Fi keep working. Another app must
pass its own service.

Known limits (keep them visible as capability results, not hidden): no live audio, Multi View
unqualified, `LunaScreenRecovery` (Color Recovery over KCP) has no caller yet. iOS-only APIs
(NEHotspotConfiguration) compile only for iOS devices; macOS and the simulator ask the operator to
join the camera Wi-Fi.

## Import rules

- No UI: never import SwiftUI, UIKit or OpenCineUI.
- No app types and no brand: app names, keychain service and log prefix come from
  `LunaIntegrationConfiguration`.
- Depends only on `../OpenCineCore` (pinned in `opencine-pins.txt`).

## Build and test

```sh
swift build && swift test                       # macOS: protocol, session, harness tests
xcodebuild -scheme Insta360Apple -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Needs a sibling `../OpenCineCore` checkout at the pinned commit (`scripts/checkout-opencine.sh`).
Hardware behavior (pairing, Wi-Fi join, settle timing) is qualified only on a physical Luna Ultra
through the consuming app.

## Kotlin

The Android `luna-adapter` still lives in OpenInstaCine: it implements that app's shell
contract (`:core-api`, `CameraBackend`/`CameraControls`/`CameraMediaStore`), which has no
OpenCineCore equivalent yet. See OpenInstaCine `docs/implementation/opencine-integration.md`.

## License

Apache 2.0 (LICENSE, NOTICE). KCP and the Luna protocol reference are MIT
(THIRD-PARTY-NOTICES.md, `Sources/CKcp/LICENSE`).
