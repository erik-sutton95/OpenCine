# Cameras join the Mac's network Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On Mac, the first pairing of a Pocket or Luna moves the camera onto the module's camera network (a router or venue Wi-Fi the Mac is also on). The camera's own Wi-Fi is never used. The network is asked for once and reused.

**Architecture:** Platform-neutral rules (host device, route choice, network reuse, interface pick, step copy) are added to shared OpenCine code with tests. The Apple station paths use the interface pick on Catalyst, and DJI stops joining the Mac itself. Each app's Mac build routes pairing through the station route and the existing network pages.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI on Mac Catalyst, NetworkExtension (`NEHotspotNetwork.fetchCurrent`), `getifaddrs` and `NWPathMonitor`.

**Spec:** `docs/superpowers/specs/2026-11-25-desktop-cameras-join-the-mac-network-design.md`. Prior work: OpenCine #403, Pocket #701, Insta #175. A code map with file:line references for every flow touched here is in the spec's "What exists" section. Re-find exact lines before editing.

## Global Constraints

- Branches: OpenCine `feat/opencine-desktop`; apps `feat/opencine-desktop-module` (worktrees under `/Volumes/OCFast/work/desktop/`). Apps build against the sibling `../OpenCine` worktree. Re-pin each app to the final OpenCine head.
- iPhone, iPad and Android behaviour and words are unchanged. Every behaviour change sits behind `HostDevice.current == .mac` or `#if targetEnvironment(macCatalyst)`.
- Shared code names no camera brand, product or app (CI rule `sharedUINamesNoBrandProductOrApp`).
- No em dash character anywhere.
- Step 3 on Mac: title "Join your network"; body "The camera joins \(network), the same network as this Mac."
- The Nikon module is not touched.
- Public API changes are recorded in the atlas API snapshots.

## Review Focus

1. A network is saved, but its password is gone from the Keychain. The next pairing must ask again, not fail silently. Test: `missingPasswordAsksAgain` (Task 2).
2. Mac on Ethernet only, with no readable Wi-Fi name. Pairing must still work through saved or typed networks, and discovery must use the Ethernet interface. Test: `ethernetOnlyMacIsUsable` (Task 3).
3. A VPN is up and owns the default route. Discovery must sweep the LAN, not the tunnel. Test: `tunnelsAndAirDropAreSkipped` (Task 3).
4. The camera joins, but the Mac is on another subnet (guest network or client isolation). The failure must name the network and say why. Test: `notFoundOnNetworkNamesItAndTheCause` (Task 1).
5. The owner changes the network. The next pairing uses the new one, and cameras already set up keep theirs. Test: `changeAppliesToTheNextPairing` (Task 2).

---

### Task 1: Host device words and route choice (OpenCineAppKit)

**Files:**

- Create: `Sources/OpenCineAppKit/HostDevice.swift`
- Modify: `Sources/OpenCineAppKit/StationNetworkSetup.swift` (route list helper), `Sources/OpenCineAppKit/PairingWizard.swift` (step 3 copy)
- Test: `Tests/OpenCineAppKitTests/HostDeviceTests.swift` (new), and the existing pairing wizard and station setup test files

**Interfaces:**

- Produces:
  - `public enum HostDevice: Sendable, Equatable { case iPhone, iPad, mac; public static var current: HostDevice { get }; public var thisDevice: String /* "this iPhone" | "this iPad" | "this Mac" */; public var isComputer: Bool }`
  - `extension StationSetupRoute { public static func offered(on host: HostDevice, hostRoutes: [StationSetupRoute]) -> [StationSetupRoute] }`: on `.mac` it returns only `.infrastructureNetwork` (plus any host route not of kind `.cameraAccessPoint` or `.phoneHotspot`); otherwise `hostRoutes` unchanged.
  - `public static func newCameraRoute(on host: HostDevice) -> RouteKind`: `.infrastructureNetwork` on `.mac`, `.cameraAccessPoint` otherwise.
  - `CamerasMapping.wizard(...)` gains `host: HostDevice = .current` and `stationNetwork: String? = nil`. When `host == .mac`, step 3's title, body and hint use the Mac copy from Global Constraints. There is no "iOS asks to join" hint and no "Camera Wi-Fi" check.
  - `public enum StationCopy { public static func notFoundOnNetwork(_ network: String, host: HostDevice) -> String }` returns "The camera joined \(network) but \(host.thisDevice) cannot reach it. Check that \(host.thisDevice) is on \(network) and that the network lets devices see each other (guest networks often do not)."

- [ ] **Step 1: Write the failing tests**

```swift
@Test func hostNouns() {
    #expect(HostDevice.iPhone.thisDevice == "this iPhone")
    #expect(HostDevice.iPad.thisDevice == "this iPad")
    #expect(HostDevice.mac.thisDevice == "this Mac")
}
@Test func macOffersOnlyTheSharedWiFi() {
    let routes = StationSetupRoute.offered(on: .mac, hostRoutes: [.init(.infrastructureNetwork), .init(.phoneHotspot), .init(.cameraAccessPoint), .init(.usb)])
    #expect(routes.map(\.kind) == [.infrastructureNetwork, .usb])
}
@Test func phoneRoutesAreUnchanged() {
    let all: [StationSetupRoute] = [.init(.infrastructureNetwork), .init(.phoneHotspot), .init(.cameraAccessPoint)]
    #expect(StationSetupRoute.offered(on: .iPhone, hostRoutes: all) == all)
}
@Test func newCameraRoutePerHost() {
    #expect(StationSetupRoute.newCameraRoute(on: .mac) == .infrastructureNetwork)
    #expect(StationSetupRoute.newCameraRoute(on: .iPhone) == .cameraAccessPoint)
}
@Test func macStepThreeCopy() { /* wizard(host: .mac, stationNetwork: "Studio") page 2: title "Join your network", body "The camera joins Studio, the same network as this Mac.", no text containing "iOS" */ }
@Test func iPhoneStepThreeCopyUnchanged() { /* wizard(host: .iPhone) page 2 equals today's strings, copied from PairingWizard.swift as literals */ }
@Test func notFoundOnNetworkNamesItAndTheCause() {
    let text = StationCopy.notFoundOnNetwork("Studio", host: .mac)
    #expect(text.contains("Studio") && text.contains("this Mac") && text.contains("guest networks"))
}
```

- [ ] **Step 2: Run and see them fail.** `swift test --filter "HostDeviceTests|PairingWizard|StationNetworkSetup"`
- [ ] **Step 3: Implement.** `HostDevice.current` is `.mac` under `#if targetEnvironment(macCatalyst) || os(macOS)`. Otherwise it is `.iPad` when `UIDevice.current.userInterfaceIdiom == .pad` (UIKit only), else `.iPhone`.
- [ ] **Step 4: Run and see them pass**, along with the full `OpenCineAppKitTests`.
- [ ] **Step 5: Commit** `feat(desktop): host device words and Mac route choice for pairing`

### Task 2: Camera network memory (OpenCineAppKit)

**Files:**

- Create: `Sources/OpenCineAppKit/CameraNetworkMemory.swift`
- Test: `Tests/OpenCineAppKitTests/CameraNetworkMemoryTests.swift`

**Interfaces:**

- Produces:
  - `public struct CameraNetworkChoice: Codable, Equatable, Sendable { public var network: String; public init(network: String) }`
  - `public enum PairingNetworkStep: Equatable, Sendable { case ask(suggested: String?); case reuse(network: String) }`
  - `public enum CameraNetworkMemory { public static func step(saved: CameraNetworkChoice?, hasPassword: (String) -> Bool, currentNetwork: String?) -> PairingNetworkStep }`: `.reuse` when `saved` exists and `hasPassword(saved.network)`. Otherwise `.ask(suggested: currentNetwork ?? saved?.network)`.
  - `public struct CameraNetworkStore { public init(defaults: UserDefaults, key: String); public func load() -> CameraNetworkChoice?; public func save(_ choice: CameraNetworkChoice) }`, stored as JSON. Passwords stay in each app's existing Keychain store.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func firstPairingAsksAndSuggestsTheMacNetwork() {
    #expect(CameraNetworkMemory.step(saved: nil, hasPassword: { _ in false }, currentNetwork: "Studio") == .ask(suggested: "Studio"))
}
@Test func savedNetworkWithPasswordIsReused() {
    #expect(CameraNetworkMemory.step(saved: .init(network: "Studio"), hasPassword: { $0 == "Studio" }, currentNetwork: "Other") == .reuse(network: "Studio"))
}
@Test func missingPasswordAsksAgain() {
    #expect(CameraNetworkMemory.step(saved: .init(network: "Studio"), hasPassword: { _ in false }, currentNetwork: nil) == .ask(suggested: "Studio"))
}
@Test func changeAppliesToTheNextPairing() {
    let defaults = UserDefaults(suiteName: "CameraNetworkMemoryTests.\(UUID())")!
    let store = CameraNetworkStore(defaults: defaults, key: "cameraNetwork")
    store.save(.init(network: "Studio"))
    store.save(.init(network: "Venue"))
    #expect(store.load() == .init(network: "Venue"))
}
```

- [ ] **Steps 2 to 5:** see them fail, implement, see them pass, then commit `feat(desktop): remember the camera network a Mac module pairs onto`.

### Task 3: Interface pick (OpenCineApple, logic in OpenCineCore)

**Files:**

- Create: `Sources/OpenCineCore/HostInterfacePick.swift` (pure), `Sources/OpenCineApple/HostInterfaces.swift` (reads the system)
- Modify: `Sources/OpenCineDJIApple/DjiAppleSharedWiFiPath.swift`, `Sources/OpenCineDJIApple/DjiAppleConnectionTransport+Native.swift`, the DJI discovery candidates, `Sources/Insta360Apple/LunaStationPath.swift` (en0 uses), `Sources/OpenCineApple/SharedWiFiPath.swift`
- Test: `Tests/OpenCineCoreTests/HostInterfacePickTests.swift`

**Interfaces:**

- Produces:
  - `public struct HostInterface: Equatable, Sendable { public var name: String; public var ipv4: String; public var prefixLength: Int; public var isUp: Bool; public var carriesDefaultRoute: Bool }`
  - `public enum HostInterfacePick { public static func stationInterfaces(_ all: [HostInterface]) -> [HostInterface] }`. It keeps up interfaces with a private IPv4 (10/8, 172.16/12, 192.168/16). It drops loopback, link-local 169.254/16, and names starting `utun`, `ipsec`, `awdl`, `llw`, `bridge`, `anpi`, `ap`, `gif`, `stf`. Order: the default route interface first, then by name.
  - `public static func sweepHosts(_ iface: HostInterface) -> [String]`: every host of the interface's /24 (narrower prefixes keep their own range), excluding its own address.
  - `HostInterfaces.current() -> [HostInterface]` in OpenCineApple: `getifaddrs` for addresses and flags. The default route comes from `NWPathMonitor`'s current path (first available interface).
- Behaviour (Catalyst only):
  - DJI `joinHost` never calls `NEHotspotConfigurationManager.apply`. It succeeds when `stationInterfaces(current())` is non-empty. Otherwise it throws with "\(HostDevice.mac.thisDevice) is not on a network". The words come from a shared constant; use "This Mac is not on a network the cameras can join."
  - `stationPathReady` and both discoveries use `stationInterfaces` instead of `en0`. They sweep each interface's hosts, the default route interface first.
  - When DJI or Luna discovery runs out of time on a station route, the failure text is `StationCopy.notFoundOnNetwork(network, host: .mac)` (Task 1).
  - iOS keeps `en0` exactly as today.

- [ ] **Step 1: Write the failing tests**

```swift
let wifi = HostInterface(name: "en1", ipv4: "192.168.1.20", prefixLength: 24, isUp: true, carriesDefaultRoute: false)
let ethernet = HostInterface(name: "en0", ipv4: "192.168.1.21", prefixLength: 24, isUp: true, carriesDefaultRoute: true)
@Test func defaultRouteComesFirst() { #expect(HostInterfacePick.stationInterfaces([wifi, ethernet]).map(\.name) == ["en0", "en1"]) }
@Test func ethernetOnlyMacIsUsable() { #expect(HostInterfacePick.stationInterfaces([ethernet]) == [ethernet]) }
@Test func tunnelsAndAirDropAreSkipped() {
    let vpn = HostInterface(name: "utun3", ipv4: "10.8.0.2", prefixLength: 24, isUp: true, carriesDefaultRoute: true)
    let awdl = HostInterface(name: "awdl0", ipv4: "192.168.9.1", prefixLength: 24, isUp: true, carriesDefaultRoute: false)
    #expect(HostInterfacePick.stationInterfaces([vpn, awdl, wifi]) == [wifi])
}
@Test func publicLinkLocalAndDownAreSkipped() { /* 169.254.3.4, 17.1.2.3 and isUp false are all dropped */ }
@Test func sweepCoversTheSubnetButNotItself() {
    let hosts = HostInterfacePick.sweepHosts(wifi)
    #expect(hosts.count == 253 && !hosts.contains("192.168.1.20") && hosts.first == "192.168.1.1")
}
```

- [ ] **Steps 2 to 4:** see them fail, implement the pure pick, then wire up the Catalyst paths. Run `swift test` (full suite) and build `OpenCineDJIApple` and `Insta360Apple` for Mac Catalyst and for the iOS Simulator.
- [ ] **Step 5: Commit** `feat(desktop): find cameras on any local interface of the Mac, not just en0`

### Task 4: Pocket and Insta Mac pairing (app repos)

**Files (each app):**

- Pocket: `ios/OpenPocketCine/StartupChrome.swift`, `AppRoot.swift` (pairing wiring), `AddSetupView.swift`, `CameraSession.swift`, `ios/OpenPocketCine/OpenPocketCine-Mac.entitlements`
- Insta: `ios/OpenInstaCine/CamerasExperience.swift`, `AppRoot.swift`, `AddSetupView.swift`, `ios/OpenInstaCine/OpenInstaCine-Mac.entitlements`
- OpenCine: `Sources/OpenCineAppKitApple/StationNetworkSetupView.swift` (use `HostDevice` words; on Mac, label the current-network section "THIS MAC IS ON" and the saved section "SAVED ON THIS MAC"), `Sources/Insta360Apple/LunaStationPath.swift` and `Sources/OpenCineApple/StationWiFiSystem.swift` (let `fetchCurrent` run on Catalyst)

**Interfaces:**

- Consumes: Tasks 1 to 3.
- Behaviour on Mac:
  1. Continue on a sighting computes `CameraNetworkMemory.step(...)`. The app's Keychain store supplies `hasPassword`; `currentNetwork` comes from `fetchCurrent`, or nil.
  2. On `.ask`, present `StationNetworkSetupView` limited to `StationSetupRoute.offered(on: .mac, ...)`, starting on the network page with `suggested` preselected. On save, store the password (the existing path) and the `CameraNetworkChoice`.
  3. Connect the sighting with an `.addRoute` draft of kind `.infrastructureNetwork` to that network.
     - Luna: `LunaIntegration.connect(_:onto:)`.
     - Pocket: build the `SavedCamera` from the sighting, then `CamerasModel.addRoute`.
  4. On `.reuse`, skip straight to step 3. The wizard shows "Cameras join \(network)" with a "Change network" action, which reopens step 2 and saves the new choice.
  5. Pass `host: .mac` and `stationNetwork:` into `wizard(...)`.
- Entitlements: add `com.apple.developer.networking.wifi-info` (true) to both Mac entitlements. The location usage text already exists in the iOS Info. Check that it is also in the Catalyst build's Info, and add it if not.
- iOS paths are unchanged (the existing tests stay green).

- [ ] **Step 1: Implement in OpenCine** (the `StationNetworkSetupView` words and the `fetchCurrent` gates), then commit `feat(desktop): Mac words and current network on the station pages` and push.
- [ ] **Step 2: Implement in each app**, then re-pin `opencine-pins.txt` to the new OpenCine head.
- [ ] **Step 3: Verify.** In each app: `just check`, an iOS Simulator build, and the app's unit tests (CI's skip list applies). Then `just macos-build -allowProvisioningUpdates`. Xcode is signed in, so it adds the Wi-Fi info capability to the module profiles. Check that the built app's entitlements include `com.apple.developer.networking.wifi-info` and `keychain-access-groups`. Run `lsregister -u` on each built app.
- [ ] **Step 4: Commit** `feat(macos): pair cameras onto the Mac's network` in each app, push, and wait for the CI gate on #403, #701 and #175.

### Task 5: Install and hardware items (main session, not the builder)

- [ ] Quit the dock (only when no input is live), run `install-local.sh` for the Pocket and Luna modules (Nikon unchanged), and relaunch. The driver is untouched.
- [ ] Add the pairing items to the desktop hardware checklist:
  - Pocket over Wi-Fi.
  - Pocket over Ethernet.
  - Luna over Wi-Fi.
  - Luna over Ethernet.
  - A second camera reuses the network.
  - Change network.
  - A wrong password shows a clear error.
