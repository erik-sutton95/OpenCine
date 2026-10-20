import Foundation
@testable import Insta360Apple
import Insta360AppleTestSupport
import Insta360Protocol
import OpenCineCore
import Testing

/// The Luna `CameraIntegration` against a scripted backend (SHELL-02 step 4). Kotlin mirror:
/// `LunaIntegrationTest`, same method names; the sighting title and scan-failure tests are Swift
/// only (Android shows the advertised name and its app gates permissions and Bluetooth).
@MainActor
@Suite struct LunaIntegrationTests {
    let port = FakeLunaPort()
    let camera = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    let when = Date(timeIntervalSince1970: 1_759_307_200)

    func integration() -> LunaIntegration { LunaIntegration(port: port, now: { [when] in when }) }

    func sighting() -> NearbyCamera {
        NearbyCamera(id: camera.uuidString, name: "Luna 1A2B", model: "Luna Ultra", routes: [.cameraAccessPoint])
    }

    @Test func discoveryListensPassivelyOverBluetooth() async {
        let luna = integration()
        #expect(luna.discoveryModes == [.passive])
        var active = 0
        for await _ in luna.discover(.active) { active += 1 }
        #expect(active == 0)

        let lists = luna.discover(.passive)
        var iterator = lists.makeAsyncIterator()
        #expect(await iterator.next() == [])
        port.emit(.discovered(MonitorCamera(id: camera, name: "Luna 1A2B", model: LunaProtocol.model, capabilities: [])))
        #expect(await iterator.next() == [sighting()])
        #expect(port.scans == 1 && port.connects.isEmpty, "listening never connects")

        let consumer = Task { for await _ in lists {} }
        consumer.cancel()
        await consumer.value
        #expect(await eventually { port.scanStops == 1 })
    }

    @Test func sightingsNameTheCameraAfterItsModel() async {
        #expect(LunaIntegration.title(advertised: " 1A2B3C ") == "Luna Ultra 1A2B3C")
        #expect(LunaIntegration.title(advertised: "Luna Ultra 1A2B") == "Luna Ultra 1A2B")
        #expect(LunaIntegration.title(advertised: "") == "Luna Ultra")
        let luna = integration()
        var iterator = luna.discover(.passive).makeAsyncIterator()
        _ = await iterator.next()
        port.emit(.discovered(MonitorCamera(id: camera, name: "1A2B", model: LunaProtocol.model, capabilities: [])))
        #expect(await iterator.next()?.map(\.name) == ["Luna Ultra 1A2B"])
    }

    @Test func aScanThatCannotStartIsReportedAndRetried() async {
        let luna = integration()
        var reported: [ConnectionFailure?] = []
        luna.onDiscoveryFailure = { reported.append($0) }
        let off = ConnectionFailure.luna(.radioOff(.bluetooth), "bluetooth.off", "off", actions: [.openSettings, .retry])
        port.scanFailure = off
        let lists = luna.discover(.passive)
        var iterator = lists.makeAsyncIterator()
        #expect(await iterator.next() == [])
        #expect(await eventually { luna.discoveryFailure == off })
        port.scanFailure = nil
        luna.retryDiscovery()
        #expect(await eventually { luna.discoveryFailure == nil })
        #expect(port.scans == 2 && reported == [off, nil])
        port.emit(.discovered(MonitorCamera(id: camera, name: "Luna 1A2B", model: LunaProtocol.model, capabilities: [])))
        #expect(await iterator.next() == [sighting()], "discovery stayed subscribed")
    }

    @Test func phasesMapToProgressAndPrompts() async throws {
        let luna = integration()
        let events = luna.connect(.nearby(sighting()))
        port.emit(.phase(.connecting))
        port.emit(.phase(.awaitingApproval))
        port.joinedNetwork = "LUNA-1A2B"
        port.emit(.phase(.readingWiFi))
        port.emit(.note("If this takes long, open Settings › Wi-Fi and join “LUNA-1A2B”."))
        port.emit(.phase(.openingVideo))
        port.emit(.phase(.streaming))
        port.connectedSerial = "SN-LUNA"
        #expect(await eventually { port.connects.count == 1 })
        port.finishConnect()

        var seen: [String] = []
        var connected: ConnectedCamera?
        for await event in events {
            switch event {
            case .progress(let progress, let prompt):
                #expect(progress.steps == LunaIntegration.steps)
                seen.append("\(progress.phase) \(progress.current) \(prompt.map(describe) ?? "-") \(progress.note ?? "-")")
            case .connected(let camera): connected = camera
            case .failed(let failure): Issue.record("failed: \(failure.code)")
            }
        }
        #expect(
            seen == [
                // The Wi-Fi step reads its phase; a backend note never replaces it (main's caption).
                "link 0 - -", "negotiating 0 - -", "awaitingApproval 0 approve: Approve on the camera -",
                "joiningNetwork 1 - Reading Wi-Fi credentials…", "link 2 - -", "link 3 - -",
            ])
        let saved = try #require(connected?.saved)
        #expect(saved.id == camera.uuidString && saved.integration == luna.id)
        #expect(saved.device == .durable("SN-LUNA", integration: luna.id) && saved.lastConnected == when)
        #expect(saved.routes.map(\.kind) == [.cameraAccessPoint] && saved.routes[0].network == "LUNA-1A2B")
        #expect(saved.routes[0].bluetooth && saved.preferredRoute == saved.routes[0].id)
        #expect(connected?.session is LunaCameraSession)
    }

    /// II-202: the baseline scanned for a few seconds and connected over Bluetooth when the camera
    /// advertised; only then did it dial saved Wi-Fi. The shared model dialled saved Wi-Fi at once.
    @Test func aSavedReconnectWaitsForTheBluetoothAdvertBeforeSavedWiFi() async throws {
        let port = FakeLunaPort()
        let gate = StepGate()
        let luna = LunaIntegration(port: port, now: { [when] in when }, sleep: { _ in await gate.wait() })
        port.savedWiFi.insert(camera)
        let ap = SavedRoute(key: "ap", kind: .cameraAccessPoint, network: "LUNA-1A2B", bluetooth: true)
        let saved = SavedCamera(
            id: camera.uuidString, integration: luna.id, advertisedName: "Luna 1A2B",
            model: LunaProtocol.model, routes: [ap], preferredRoute: ap.id)
        let events = luna.connect(.saved(saved, route: ap.id))
        var seen: [(phase: ConnectionPhase, note: String?)] = []
        let consumer = Task {
            for await case .progress(let progress, _) in events {
                seen.append((progress.phase, progress.note))
            }
        }
        // The grace is running: no Wi-Fi dial yet, and the card says it is looking.
        #expect(await eventually { gate.waits == 1 })
        #expect(port.connects.isEmpty, "the saved Wi-Fi path must wait for the advert")
        #expect(await eventually { seen.contains { $0.note == "Looking for the camera" } })
        // The camera now advertises: Bluetooth is the route the backend takes.
        port.seen.insert(camera)
        port.emit(.discovered(MonitorCamera(
            id: camera, name: "Luna 1A2B", model: LunaProtocol.model, capabilities: [])))
        gate.release()
        #expect(await eventually { port.connects.count == 1 })
        port.finishConnect()
        await consumer.value
        #expect(port.connectSawSighting == true, "the advert chose the Bluetooth bootstrap")
        #expect(!seen.contains { $0.phase == .joiningNetwork }, "saved Wi-Fi is not dialled before the advert")
    }

    @Test func theSightingGraceKeepsTheScanWhenTheLastListenerLeaves() async throws {
        let port = FakeLunaPort()
        let gate = StepGate()
        let luna = LunaIntegration(port: port, now: { [when] in when }, sleep: { _ in await gate.wait() })
        port.savedWiFi.insert(camera)
        let listening = Task { for await _ in luna.discover(.passive) {} }
        #expect(await eventually { port.scans == 1 })
        let ap = SavedRoute(key: "ap", kind: .cameraAccessPoint, network: "LUNA-1A2B", bluetooth: true)
        let saved = SavedCamera(
            id: camera.uuidString, integration: luna.id, advertisedName: "Luna 1A2B",
            model: LunaProtocol.model, routes: [ap], preferredRoute: ap.id)
        let consumer = Task { for await _ in luna.connect(.saved(saved, route: ap.id)) {} }
        #expect(await eventually { gate.waits == 1 })
        listening.cancel()
        await listening.value
        #expect(port.scanStops == 0, "the grace still needs the scan after the last listener leaves")
        port.seen.insert(camera)
        gate.release()
        #expect(await eventually { port.connects.count == 1 })
        port.finishConnect()
        await consumer.value
    }

    @Test func aSavedCameraKeepsItsRecord() async throws {
        let luna = integration()
        let ap = SavedRoute(key: "ap", kind: .cameraAccessPoint, network: "LUNA-OLD", bluetooth: true)
        let saved = SavedCamera(
            id: camera.uuidString, integration: luna.id, name: "A cam", advertisedName: "Luna 1A2B",
            model: LunaProtocol.model, routes: [ap], extras: ["lastSetup": "wifi"])
        let events = luna.connect(.saved(saved, route: ap.id))
        #expect(await eventually { port.connects.map(\.id) == [camera] })
        port.finishConnect()
        var record: SavedCamera?
        for await case .connected(let camera) in events { record = camera.saved }
        #expect(record?.name == "A cam" && record?.routes == [ap] && record?.extras == ["lastSetup": "wifi"])
        #expect(record?.device == nil, "no serial was read")
    }

    /// A legacy hotspot setup (main's records could carry one) is no dead chip: Luna dials the
    /// camera over its own Wi-Fi, keeps the setup, and makes the camera Wi-Fi preferred again.
    @Test func aLegacyHotspotSetupConnectsOverCameraWiFi() async throws {
        let luna = integration()
        let ap = SavedRoute(key: "ap", kind: .cameraAccessPoint, network: "LUNA-1A2B", bluetooth: true)
        let hotspot = SavedRoute(key: "hotspot", kind: .phoneHotspot, network: "Rig iPhone")
        let saved = SavedCamera(
            id: camera.uuidString, integration: luna.id, advertisedName: "Luna 1A2B", model: LunaProtocol.model,
            routes: [ap, hotspot], preferredRoute: hotspot.id)
        let events = luna.connect(.saved(saved, route: hotspot.id))
        #expect(await eventually { port.connects.map(\.id) == [camera] })
        port.finishConnect()
        var record: SavedCamera?
        for await case .connected(let camera) in events { record = camera.saved }
        #expect(record?.routes == [ap, hotspot] && record?.preferredRoute == ap.id)
    }

    @Test func typedFailuresKeepTheirCopy() async throws {
        // At the backend's own throw sites.
        do {
            try await LunaCameraBackend(useExistingNetwork: true).startScan()
            Issue.record("expected a failure off the camera network")
        } catch let failure as ConnectionFailure {
            #expect(failure.reason == .notFound && failure.actions == [.retry])
            #expect(failure.localizedDescription == "Join the Luna camera Wi-Fi on this device before opening the feed.")
            #expect(failure.code == "com.opencapture.insta360.luna.existing-network.absent")
        }
        do {
            _ = try await LunaCameraBackend().send(LunaProtocol.wifiCredentialsRequest)
            Issue.record("expected a closed link")
        } catch let failure as ConnectionFailure {
            #expect(failure.reason == .linkLost && failure.message == "The camera connection is not open.")
        }

        // Through an attempt: the phase it failed in is kept; an untyped error reads as .other.
        let luna = integration()
        let approval = luna.connect(.nearby(sighting()))
        port.emit(.phase(.awaitingApproval))
        #expect(await eventually { port.connects.count == 1 })
        port.finishConnect(throwing: ConnectionFailure(
            reason: .notApproved, title: "t", message: "Approval timed out.", actions: [.retry], code: "c"))
        let first = try #require(await failure(of: approval))
        #expect(first.reason == .notApproved && first.phase == .awaitingApproval)
        // Time-outs and dropped links read as OpenInstaCine has always shown them.
        #expect(first.message.hasPrefix("The camera didn't respond in time. Check Bluetooth, force quit the Insta360 app"))

        let other = luna.connect(.nearby(sighting()))
        #expect(await eventually { port.connects.count == 2 })
        port.finishConnect(throwing: URLError(.timedOut))
        let second = try #require(await failure(of: other))
        #expect(second.reason == .other && second.phase == .link)
        #expect(second.code == "com.opencapture.insta360.luna.unexpected")
        #expect(
            LunaIntegration.operatorMessage("Camera Wi-Fi disconnected")
                == "The camera ended the connection. Force quit the Insta360 app on every phone near the camera, then try again.")
        #expect(LunaIntegration.operatorMessage("The camera is no longer nearby.") == "The camera is no longer nearby.")
    }

    @Test func aNewerAttemptEndsTheOlder() async {
        let luna = integration()
        let a = luna.connect(.nearby(sighting()))
        #expect(await eventually { port.connects.count == 1 })
        let b = luna.connect(.nearby(sighting()))
        #expect(await eventually { port.connects.count == 2 })
        port.emit(.phase(.awaitingApproval))
        var eventsA = 0
        for await _ in a { eventsA += 1 }
        #expect(eventsA == 1, "only its own first progress")
        port.finishConnect()
        var phases: [ConnectionPhase] = []
        for await case .progress(let progress, _) in b { phases.append(progress.phase) }
        #expect(phases == [.link, .awaitingApproval])
    }

    @Test func replacingBeforeTheTaskStartsDoesNotConnectTheOldCamera() async {
        let luna = integration()
        let previous = luna.connect(.nearby(sighting()))
        var replacement = sighting()
        replacement.id = UUID().uuidString
        let current = luna.connect(.nearby(replacement))
        #expect(await eventually { port.connects.last?.id.uuidString == replacement.id })
        #expect(port.connects.map(\.id.uuidString) == [replacement.id])
        port.finishConnect()
        var connectedIDs: [String] = []
        for await case .connected(let camera) in current { connectedIDs.append(camera.saved.id) }
        #expect(connectedIDs == [replacement.id])
        for await event in previous {
            if case .connected = event { Issue.record("The replaced attempt connected") }
        }
    }

    @Test func cancellingTheConsumerDisconnects() async {
        let luna = integration()
        let events = luna.connect(.nearby(sighting()))
        #expect(await eventually { port.connects.count == 1 })
        let consumer = Task { for await _ in events {} }
        consumer.cancel()
        await consumer.value
        #expect(await eventually { port.disconnects == 1 })
    }

    @Test func forgetDropsTheSavedWiFiOnly() async {
        let luna = integration()
        await luna.forget(SavedCamera(id: camera.uuidString, integration: luna.id, advertisedName: "", model: ""))
        await luna.forget(SavedCamera(id: "AA:BB:CC:DD:EE:01", integration: luna.id, advertisedName: "", model: ""))
        #expect(port.forgotten == [camera])
    }

    @Test func addingARouteIsUnsupported() async {
        let luna = integration()
        let saved = SavedCamera(id: camera.uuidString, integration: luna.id, advertisedName: "", model: "")
        let failed = await failure(of: luna.connect(.addRoute(saved, RouteDraft(kind: .infrastructureNetwork))))
        #expect(failed?.reason == .unsupported && port.connects.isEmpty)
    }

    func failure(of events: AsyncStream<ConnectionEvent>) async -> ConnectionFailure? {
        for await case .failed(let failure) in events { return failure }
        return nil
    }

    func describe(_ prompt: ConnectionPrompt) -> String {
        switch prompt {
        case .approveOnCamera(let text): "approve: \(text)"
        case .acceptNetworkJoin(let network, let text): "join \(network): \(text)"
        case .integration(let prompt): "integration: \(prompt.fallbackText)"
        }
    }
}

/// A controlled sleep: `wait()` suspends until the test releases it, so a grace loop can be
/// observed and released without wall-clock waiting.
@MainActor
private final class StepGate {
    private(set) var waits = 0
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        waits += 1
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        waiter?.resume()
        waiter = nil
    }
}

/// Yields until `condition` holds (other suites share the main actor). Tests never sleep.
@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<10_000 where !condition() { await Task.yield() }
    return condition()
}
