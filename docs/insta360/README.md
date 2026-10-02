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
- Depends only on `OpenCineCore` (same package; root `Package.swift`).

## Build and test

```sh
swift build && swift test --filter Insta360    # macOS: protocol, session, harness tests
xcodebuild -scheme Insta360Apple -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Hardware behavior (pairing, Wi-Fi join, settle timing) is qualified only on a physical Luna Ultra
through the consuming app.

## Kotlin (Android/)

Two modules of the platform Gradle build (`Android/` at the repository root: one wrapper and
version catalog, AGP/Kotlin matching the apps); `:insta360-shell` depends on `project(":core")`.

| Module | Coordinate | What it holds |
|---|---|---|
| `:insta360-shell` | `com.opencapture.opencine:insta360-shell` | Kotlin/JVM app shell contract, the Kotlin twin of the Swift `CameraBackend` seam: `CameraBackend` (discovery, connection, frames), `CameraControls` (Luna live controls), `CameraMediaStore`, `CoreSessionSource` (hands out the OpenCineCore `CameraSession`) and their Luna-shaped values. Package `com.opencapture.opencine.insta360.shell`. |
| `:insta360-luna` | `com.opencapture.opencine:insta360-luna` | Android library: `LunaBackend` (BLE, camera Wi-Fi, TCP 6666, HEVC preview, media), `LunaCameraSession` (OpenCineCore session), wire/status/IMU code. Package and namespace `com.opencapture.opencine.insta360.luna`. compileSdk 37, no AAR-metadata exemption. |

The shell contract is not in OpenCineCore: its values are Luna-shaped (shooting, gimbal and focus
modes, program and storage codes) and Core already owns the neutral command and state contract.
Moved from OpenInstaCine `:core-api` and `luna-adapter` (CORE-API); OpenPocketCine's
`ConnectionPhase` stays with the DJI integration.

`LunaBackend(context, savedWifi, saveWifi, clientIdentityPreferences)`: the last argument names the
SharedPreferences file holding the camera authorization identity. Its default
`openinstacine.client-identity` keeps OpenInstaCine's saved approvals; another app passes its own.

```sh
cd Android && ./gradlew :insta360-shell:test :insta360-luna:test :insta360-luna:lint :insta360-luna:assembleRelease
```

A consumer includes the platform build by name and substitutes both coordinates (plus any other
OpenCine modules it uses, in the same block):

```kotlin
includeBuild("../../../OpenCine/Android") {
    name = "opencine"
    dependencySubstitution {
        substitute(module("com.opencapture.opencine:insta360-shell")).using(project(":insta360-shell"))
        substitute(module("com.opencapture.opencine:insta360-luna")).using(project(":insta360-luna"))
    }
}
```

## License

Apache 2.0 (root LICENSE, NOTICE). KCP and the Luna protocol reference are MIT
(root THIRD-PARTY-NOTICES.md, `Sources/CKcp/LICENSE`).
