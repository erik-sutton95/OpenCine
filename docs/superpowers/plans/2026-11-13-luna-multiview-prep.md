# Luna Multiview prep: return to access point, LAN-first reconnect, nearby onto a network

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Luna integration (Swift `Insta360Apple`, Kotlin `:insta360-luna`, twins with the
same names) the three operations Pocket-standard Multiview needs from it, unit-tested against
scripted links and fakes, all hardware-untested: a standalone, retryable return to the camera's
own Wi-Fi; a LAN-first reconnect for Wi-Fi and hotspot setups; and a nearby camera connected
straight onto a given network.

**Architecture:** Each operation's decisions live in a small integration-internal unit that takes
its links as closures (the pattern of `LunaStationJoin` and `LunaStationPath.findRequestedCamera`),
so tests drive it with scripted cameras and a manual clock. The backends (`LunaCameraBackend`,
`LunaBackend`) wire those units to Bluetooth, the phone's network path and the control link. The
integration (`LunaIntegration` on both platforms) exposes the operations through its port. The
shapes stay neutral so Plan 5 can adapt them to the Plan 2 seams: the return maps onto
`StationCommissioner`'s "restore its own access point (retryable)", the LAN-first reconnect onto
`MultiviewMemberLink`'s "open at an address with identity check", and the nearby target onto
`StationCommissioner`'s "commission onto a `StationNetwork`".

**Tech Stack:** Swift 6 (SwiftPM, Swift Testing), Kotlin (JVM 17, coroutines test), no new
dependencies.

**Spec:** `docs/superpowers/specs/2026-11-13-shared-multiview-design.md` ("New integration work",
Luna column of "Per camera"); series: `docs/superpowers/plans/2026-11-13-shared-multiview-roadmap.md`
(Plan 5, integration part). Base: `fix/insta360-shared-network` (PR #346).

## Global Constraints

- OpenCine `AGENTS.md`: integration code only (no app, no AppKit Multiview seam); Swift and
  Kotlin twins change together with the same type and test names; no em dash character anywhere;
  Conventional Commits, no co-author trailers, stage files explicitly; behavior tests at contract
  boundaries; no sleeps (manual clocks and coroutine virtual time).
- Insta360 rules: nothing process-wide; commands only through `LunaCameraSession` for camera
  controls (these operations send Wi-Fi role and connection requests only, never a record
  command); keep the keychain service and `DEFAULT_CLIENT_IDENTITY_PREFERENCES`.
- Pocket parity: closing returns cameras to their own Wi-Fi, a temporary refusal gets a bounded
  automatic retry, "No stop-recording command is sent. Recording continues." (Pocket handbook,
  Network setup and recovery).
- Keep `cameraScansNetworks: false` semantics: the Luna has no verified camera-driven network
  scan; nothing here claims one.
- Public API changes update snapshots in the same change: `python3 atlas/tools/atlas.py api --write --build`
  and `cd Android && ./gradlew updateKotlinAbi updateAndroidApi`.
- Build scratch on `/Volumes/OCScratch/luna/` (Swift `--scratch-path`, Gradle `--project-cache-dir`).

## Review Focus

- The return to access point sends exactly one request after authorization: SET_WIFI_MODE 147
  with the access point body (the camera's region when the credential read names one). No capture,
  record or live command (Task 1 test).
- Retry happens only on a deferred result (not reachable over Bluetooth, busy switching, no
  answer); a refusal or an approval that did not complete is not retried; cancellation is never a
  result (Task 1 tests).
- LAN-first never runs the Bluetooth move when the known host answers as this camera; it never
  tries a host another connection holds, a host from another network, or one without a known
  serial; a known host that answers as another camera, or not at all, falls back to the Bluetooth
  move; Local Network permission denial and cancellation do not fall back (Task 2 tests).
- On Android the control link runs for the whole session: a failure after the camera went live
  must end the connect, never start a Bluetooth move (Task 2 test via `reached`).
- The nearby-onto-network target produces the same record and stored password as Add setup, and
  remembers the move before it happens (Task 3 tests).

---

### Task 1: Return to the camera's own Wi-Fi (standalone, retryable)

**Files:**
- Create: `Sources/Insta360Apple/LunaAccessPointReturn.swift`,
  `Android/insta360-luna/src/main/kotlin/com/opencapture/opencine/insta360/luna/LunaAccessPointReturn.kt`
- Modify: `Sources/Insta360Apple/LunaCameraBackend.swift` (split `authorizeOverBluetooth` into the
  Bluetooth link and the authorization, a quiet mode that reports no connect phases, and
  `returnToAccessPoint(cameraID:)`), `Sources/Insta360Apple/LunaIntegration.swift` (port
  requirement with an unsupported default, integration method),
  `Sources/Insta360AppleTestSupport/FakeLunaPort.swift` (scripted results),
  `Android/.../LunaBackend.kt` (same split, `returnToAccessPoint(id)` run as the backend's job),
  `Android/.../LunaIntegration.kt` (port default, integration method)
- Test: `Tests/Insta360AppleTests/LunaAccessPointReturnTests.swift`,
  `Android/insta360-luna/src/test/kotlin/.../LunaAccessPointReturnTest.kt`, and one test each in
  `LunaIntegrationTests` / `LunaIntegrationTest`

**Interfaces (Swift; Kotlin twin has the same names):**
```swift
public enum LunaAccessPointReturn: Equatable, Sendable {
    case returned
    case deferred(ConnectionFailure)   // retry later: not reachable, busy switching, no answer
    case failed(ConnectionFailure)     // retrying now will not help: refused, not authorized
    public var isRetryable: Bool
    /// DJI `restoreCameraWiFiWithRetry`: up to `attempts`, waiting between deferred results.
    public static func retrying(attempts: Int = 3, waitBetween: () async throws -> Void,
        _ attempt: () async throws -> LunaAccessPointReturn) async throws -> LunaAccessPointReturn
}
struct LunaAccessPointRestore {          // internal
    var link: () async throws -> Void            // Bluetooth reaches the camera
    var authorize: () async throws -> Data       // approval and credential read; the reply
    var send: (LunaRequest) async throws -> Void // one encrypted request on that link
    var close: () -> Void                        // always, after any outcome
    func run() async throws -> LunaAccessPointReturn   // throws CancellationError only
}
// LunaConnectPort: func returnToAccessPoint(cameraID: UUID) async throws -> LunaAccessPointReturn
// LunaIntegration: func returnToAccessPoint(_ camera: SavedCamera) async throws -> LunaAccessPointReturn
// LunaCameraBackend: func returnToAccessPoint(cameraID: UUID) async throws -> LunaAccessPointReturn
```
Kotlin: `sealed interface LunaAccessPointReturn { Returned; Deferred(failure); Failed(failure) }`
with `companion suspend fun retrying(attempts = 3, waitBetween = { delay(3_000) }, attempt)`;
`internal class LunaAccessPointRestore(link, authorize: suspend () -> ByteArray, send: suspend (Int, ByteArray) -> Unit, close)`.

Classification (both platforms): link failure is deferred (`return.not-reachable`); during
authorization a 505 is deferred (`return.camera-busy`), a timeout deferred (`return.no-answer`),
anything else failed (`return.not-authorized`); on the switch a 505 is deferred, a refusal (500)
failed (`return.refused`), anything else deferred (`return.no-answer`).

- [ ] Write the restore and retry tests (Swift and Kotlin): only 147 access point with the region
  is sent; the link is closed on every path; each classification; retry stops on returned and on
  failed, retries deferred up to the limit and waits only between attempts; cancellation
  propagates. Integration test: the integration asks the port for the saved camera and ends an
  attempt in flight first.
- [ ] Run them: they fail (types missing).
- [ ] Implement the units, wire the backends (quiet authorization: no phase events, no session
  link change; the backend's own link and connect job are ended first, which never sends a
  record command), add the port requirement and integration method, update `FakeLunaPort`.
- [ ] Run the tests: pass. Commit `feat(insta360): return a Luna to its own Wi-Fi on its own`.

### Task 2: LAN-first reconnect for Wi-Fi and hotspot setups

**Files:**
- Create: `Sources/Insta360Apple/LunaStationReconnect.swift`,
  `Android/.../LunaStationReconnect.kt`
- Modify: `Sources/Insta360Apple/LunaCameraBackend.swift` (station branch: known host first, then
  the Bluetooth move; remember the host and serial after a station connect; forget it on camera
  Wi-Fi, on a return to the access point and on forget; `stationHost(for:)` and
  `rememberStationHost(_:for:)`), `Android/.../LunaBackend.kt` (same; `moveToStation` split into
  the Bluetooth move and the phone side of the network; `runLive` reports when the camera is live)
- Test: `Tests/Insta360AppleTests/LunaStationReconnectTests.swift`,
  `Android/.../LunaStationReconnectTest.kt`

**Interfaces (Swift; Kotlin twin has the same names):**
```swift
public struct LunaStationHost: Equatable, Sendable {   // where a camera was last reached
    public var network: String; public var hotspot: Bool; public var host: String; public var serial: String
    public func isOn(_ network: LunaStationNetwork) -> Bool
}
enum LunaStationReconnect {   // internal
    enum Path: Equatable { case direct, bluetooth }
    /// `known` on `network` and not in `inUse`: `direct(known)` first; its failure, unless
    /// cancellation, Local Network denial or `reached()`, runs `move()`.
    static func run(known: LunaStationHost?, network: LunaStationNetwork, inUse: Set<String>,
        reached: () -> Bool = { false }, log: (String) -> Void = { _ in },
        direct: (LunaStationHost) async throws -> Void, move: () async throws -> Void) async throws -> Path
}
```
The direct step (backends): put the phone on the network (no Bluetooth), probe the known host,
open the control link there with the known serial as the expected serial; a mismatch closes the
link before anything else is sent. The Bluetooth move also prefers the known host in its search.

- [ ] Write the tests (Swift and Kotlin): known host answering as this camera never moves the
  camera; no known host, a host on another network or another hotspot flag, and a host in use go
  straight to the move; direct failure as another camera or not found falls back once; Local
  Network denial and cancellation do not fall back; a failure after `reached()` ends the connect.
- [ ] Run them: they fail.
- [ ] Implement the unit and wire both backends.
- [ ] Run the tests: pass. Commit `feat(insta360): reconnect a Luna on its known network address first`.

### Task 3: A nearby camera onto a Wi-Fi or hotspot setup as a connect target

**Files:**
- Modify: `Sources/Insta360Apple/LunaIntegration.swift`, `Android/.../LunaIntegration.kt`
- Test: `LunaIntegrationTests` / `LunaIntegrationTest` (same method names)

**Interfaces (Swift; Kotlin twin has the same names):**
```swift
extension LunaIntegration {
    /// The target that moves a Bluetooth sighting onto `network` and finds it there: an Add setup
    /// on a record made from the sighting. The connected event carries the session and the record
    /// with the station route preferred.
    public static func target(_ nearby: NearbyCamera, onto network: LunaStationNetwork) -> ConnectTarget
    public func connect(_ nearby: NearbyCamera, onto network: LunaStationNetwork) -> AsyncStream<ConnectionEvent>
}
```
- [ ] Write the tests: a sighting connects with the station route and the given password, the
  password is kept, the record is saved before the move, the connected record has the access point
  and the station route with the station route preferred and the serial; a hotspot network gives a
  hotspot route.
- [ ] Run them: they fail.
- [ ] Implement.
- [ ] Run the tests: pass. Commit `feat(insta360): connect a nearby Luna straight onto a network`.

### Task 4: Bluetooth sightings across backends (check)

- [ ] Read `LunaBluetooth.connect(id:)` and the Kotlin GATT path for a camera another backend
  sighted. Fix only if a backend cannot reach such a camera; otherwise record the finding in the
  report and the README.

### Task 5: Docs, snapshots, verification

**Files:** `docs/insta360/README.md`, `atlas/api/swift/Insta360Apple.txt`,
`Android/insta360-luna/api/*.api`

- [ ] README: the three operations, hardware-untested; the Luna has no verified camera-driven
  network scan (`cameraScansNetworks: false` stays); the cross-backend Bluetooth finding.
- [ ] Snapshots: `atlas api --write --build`, `./gradlew updateKotlinAbi updateAndroidApi`.
- [ ] Gates: `swift build --build-tests -Xswiftc -strict-concurrency=complete`,
  `swift test --filter 'Insta360|Luna'`, `./gradlew :insta360-luna:test :insta360-shell:test
  :platform:test :insta360-luna:lint`, `atlas check`.
- [ ] Commit `docs(insta360): Multiview operations, hardware-untested`.
