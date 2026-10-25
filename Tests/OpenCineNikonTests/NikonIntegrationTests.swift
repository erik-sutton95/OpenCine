import Foundation
import OpenCineCore
import OpenCineCoreTestSupport
import OpenCineMedia
import OpenCineNikon
import Testing

/// A scripted Nikon pipeline: it records discovery modes, connects, cancels and forgets, holds each
/// connect until the test finishes it, and serves saved records the test sets.
@MainActor
final class FakeNikonPort: NikonConnectPort {
    var onSightings: (([DiscoveredCamera]) -> Void)?
    var onPhase: ((CameraConnectionPhase, String?) -> Void)?
    var savedRecords: [PTPIPSavedCameraRecord] = []
    /// Every discovery start, and `nil` for a stop.
    private(set) var discovery: [DiscoveryMode?] = []
    private(set) var connects: [NikonConnectRequest] = []
    private(set) var cancels = 0
    private(set) var forgotten: [[String]] = []
    private var pending: CheckedContinuation<NikonConnection, Error>?

    func startDiscovery(_ mode: DiscoveryMode) { discovery.append(mode) }
    func stopDiscovery() { discovery.append(nil) }

    func connect(_ request: NikonConnectRequest) async throws -> NikonConnection {
        connects.append(request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    private(set) var consentedRequests: [NikonConnectRequest] = []

    func connect(_ request: NikonConnectRequest, takingOverConfirmed: Bool) async throws
        -> NikonConnection
    {
        if takingOverConfirmed { consentedRequests.append(request) }
        return try await connect(request)
    }

    func finish(_ result: Result<NikonConnection, Error>) {
        let waiter = pending
        pending = nil
        waiter?.resume(with: result)
    }

    func cancel() {
        cancels += 1
        finish(.failure(CancellationError()))
    }

    func forget(hosts: [String]) { forgotten.append(hosts) }

    /// The presence lookup's answer, and every host it was asked about.
    var holder: String?
    private(set) var holderQueries: [String] = []
    func currentHolder(of host: String) async -> String? {
        holderQueries.append(host)
        return holder
    }
}

/// A pre-consent-overload port; the public default must preserve its own admission failure.
@MainActor
private final class LegacyNikonPort: NikonConnectPort {
    var onSightings: (([DiscoveredCamera]) -> Void)?
    var onPhase: ((CameraConnectionPhase, String?) -> Void)?
    var savedRecords: [PTPIPSavedCameraRecord] = []
    var requests: [NikonConnectRequest] = []
    let failure = ConnectionFailure(
        reason: .heldElsewhere, title: "Held", message: "Consent required", actions: [.retry],
        code: "SIMULATED.legacy")
    func startDiscovery(_ mode: DiscoveryMode) {}
    func stopDiscovery() {}
    func connect(_ request: NikonConnectRequest) async throws -> NikonConnection {
        requests.append(request)
        throw failure
    }
    func cancel() {}
    func forget(hosts: [String]) {}
}

/// The Nikon `CameraIntegration` against a scripted pipeline. Kotlin mirror: `NikonIntegrationTest`,
/// same method names.
@MainActor
@Suite struct NikonIntegrationTests {
    let port = FakeNikonPort()
    static let when = Date(timeIntervalSinceReferenceDate: 781_000_000)

    /// One body with an access-point and a Studio Wi-Fi setup, and one camera without a serial.
    static let records = [
        PTPIPSavedCameraRecord(
            host: "192.168.1.1", displayName: "ZR_3001234", transport: "Wi-Fi", lastSeenAt: when, serialNumber: "3001234",
            path: .cameraAccessPoint(ssid: "NIKON_ZR_3001234")),
        PTPIPSavedCameraRecord(
            host: "192.168.50.23", displayName: "ZR_3001234", transport: "Wi-Fi", lastSeenAt: when.addingTimeInterval(60),
            serialNumber: "3001234", path: .infrastructure(networkName: "Studio")),
        PTPIPSavedCameraRecord(
            host: "172.20.10.3", displayName: "ZR_4005678", transport: "Wi-Fi", lastSeenAt: when, path: .phoneHotspot),
    ]

    func integration() -> NikonIntegration {
        port.savedRecords = Self.records
        return NikonIntegration(port: port)
    }

    func outcome(_ events: AsyncStream<ConnectionEvent>) async -> (progress: [ConnectionProgress], prompts: [String?], end: ConnectionEvent?) {
        var progress: [ConnectionProgress] = []
        var prompts: [String?] = []
        var end: ConnectionEvent?
        for await event in events {
            if case .progress(let value, let prompt) = event {
                progress.append(value)
                prompts.append(prompt?.text)
            } else {
                end = event
            }
        }
        return (progress, prompts, end)
    }

    /// The passive-only rule at the integration: the cameras list runs passive discovery; only a
    /// pairing listener ever turns it active, and it falls back to passive when that one leaves.
    @Test func theCamerasListNeverAsksForActiveDiscovery() async {
        let nikon = integration()
        let passive = Task { for await _ in nikon.discover(.passive) {} }
        #expect(await eventually { port.discovery == [.passive] })
        let pairing = Task { for await _ in nikon.discover(.active) {} }
        #expect(await eventually { port.discovery == [.passive, .active] })
        pairing.cancel()
        #expect(await eventually { port.discovery == [.passive, .active, .passive] })
        passive.cancel()
        #expect(await eventually { port.discovery == [.passive, .active, .passive, nil] })
        #expect(port.connects.isEmpty, "discovering never connects")
    }

    @Test func sightingsNameTheirSavedCamera() async {
        let nikon = integration()
        let lists = nikon.discover(.passive)
        var iterator = lists.makeAsyncIterator()
        #expect(await iterator.next() == [])
        port.onSightings?([
            DiscoveredCamera(ip: "192.168.50.23", source: .liveness),
            DiscoveredCamera(ip: "192.168.50.99", source: .liveness),
            DiscoveredCamera(ip: "192.168.50.40", name: "Z_8_7000001", source: .bonjour),
            DiscoveredCamera(ip: "192.168.50.41", source: .heldByAnotherDevice, heldByDeviceName: "Phone B"),
            DiscoveredCamera(ip: "usb:0x99", name: "Z_6_3_8000001", source: .usb),
        ])
        let list = await iterator.next() ?? []
        #expect(list.map(\.id) == ["192.168.50.23", "192.168.50.40", "192.168.50.41", "usb:0x99"])
        #expect(list.map(\.savedID) == ["serial:3001234", nil, nil, nil])
        #expect(
            list.map(\.availability) == [.available, .available, .unavailable(.busy), .available])
        #expect(
            list.map(\.routes) == [
                [.infrastructureNetwork], [.infrastructureNetwork], [.infrastructureNetwork],
                [.usb],
            ])
    }

    @Test func sightingsNameTheSetupTheyReach() async {
        port.savedRecords = Self.records + [
            PTPIPSavedCameraRecord(
                host: "usb:0x10", displayName: "ZR_3001234", transport: "USB-C", lastSeenAt: Self.when,
                serialNumber: "3001234", path: .usbC)
        ]
        let nikon = NikonIntegration(port: port)
        var iterator = nikon.discover(.passive).makeAsyncIterator()
        #expect(await iterator.next() == [])
        port.onSightings?([
            // Its Studio setup's address; the access point's (no proof off its network); a cable; elsewhere.
            DiscoveredCamera(ip: "192.168.50.23", source: .liveness),
            DiscoveredCamera(ip: "192.168.1.1", name: "ZR_3001234", source: .bonjour),
            DiscoveredCamera(ip: "usb:0x77", name: "ZR_3001234", source: .usb),
            DiscoveredCamera(ip: "10.1.1.7", name: "ZR_3001234", source: .bonjour),
        ])
        let list = await iterator.next() ?? []
        #expect(list.map(\.savedID) == Array(repeating: "serial:3001234", count: 4))
        #expect(list.map(\.routeKey) == ["infrastructure|Studio", nil, "usbC", nil])
    }

    @Test func connectedServicesPreserveExactInstanceAndDefaultEmpty() async throws {
        let nikon = integration()
        let camera = try #require(NikonSavedRecordsV0.cameras(from: Self.records).first)
        let studio = try #require(camera.routes.first { $0.key == "infrastructure|Studio" })
        let native = FakeCameraSession.nikonLike()
        let marker = IntegrationMediaMarker(sessionID: native.id)
        var services = CameraServices()
        services.register(marker, as: (any CameraMediaService).self)
        let defaults = NikonConnection(
            session: native, host: "192.168.50.23", path: .infrastructure)
        #expect(defaults.services[(any CameraMediaService).self] == nil)
        let events = nikon.connect(.saved(camera, route: studio.id))
        #expect(await eventually { port.connects.count == 1 })
        port.finish(.success(.init(session: native, host: "192.168.50.23", path: .infrastructure, services: services)))
        let (_, _, end) = await outcome(events)
        guard case .connected(let camera) = end else {
            Issue.record("not connected")
            return
        }
        #expect(camera.services[(any CameraMediaService).self] === marker)
        #expect(camera.session.id == marker.sessionID)
    }

    @Test func aSavedSetupConnectsThroughTheAppFunnel() async throws {
        let nikon = integration()
        let camera = try #require(NikonSavedRecordsV0.cameras(from: Self.records).first)
        let studio = try #require(camera.routes.first { $0.key == "infrastructure|Studio" })
        let events = nikon.connect(.saved(camera, route: studio.id))
        #expect(await eventually { port.connects.count == 1 })
        #expect(port.connects == [.saved(host: "192.168.50.23", path: .infrastructure)])
        for phase in [CameraConnectionPhase.discovering, .handshaking, .preparingLiveView] { port.onPhase?(phase, nil) }
        port.finish(.success(NikonConnection(session: FakeCameraSession.nikonLike(), host: "192.168.50.23", path: .infrastructure)))
        let (progress, prompts, end) = await outcome(events)
        #expect(
            progress.map { "\($0.phase) \($0.current)" } == [
                "link 0", "negotiating 1", "negotiating 2",
            ])
        #expect(
            progress[0].steps.map(\.title) == [
                "Finding the camera", "Connecting", "Starting live view",
            ])
        #expect(prompts == [nil, nil, nil])
        guard case .connected(let connected) = end else {
            Issue.record("not connected")
            return
        }
        #expect(connected.saved.id == "serial:3001234")
        #expect(connected.saved.routes.map(\.id) == camera.routes.map(\.id), "route ids survive the read-back")
        #expect(connected.saved.preferredRoute == studio.id)
    }

    @Test func theAccessPointAsksToJoinAndThePairingAsksTheCamera() async throws {
        let nikon = integration()
        let camera = try #require(NikonSavedRecordsV0.cameras(from: Self.records).first)
        let ap = try #require(camera.routes.first { $0.kind == .cameraAccessPoint })
        let events = nikon.connect(.saved(camera, route: ap.id))
        #expect(await eventually { port.connects == [.saved(host: "192.168.1.1", path: .cameraAccessPoint)] })
        port.onPhase?(.joiningWiFi, nil)
        port.onPhase?(.discovering, nil)
        port.onPhase?(.pairing, "Pairing with code 1234…")
        port.onPhase?(.pairing, "Pairing with code 1234…")
        port.finish(.failure(NativeCameraSessionError.pairingRejected))
        let (progress, prompts, end) = await outcome(events)
        #expect(progress.map(\.current) == [0, 1, 1])
        #expect(progress[0].steps.first?.title == "Joining the camera’s Wi-Fi")
        #expect(
            prompts == [
                ConnectionProgressCopy.statusDetail(
                    phase: .joiningWiFi, deviceName: "ZR_3001234", friendlyError: nil), nil,
                "Pairing with code 1234…",
            ])
        guard case .failed(let failure) = end else {
            Issue.record("not failed")
            return
        }
        #expect(failure.reason == .notApproved && failure.phase == .awaitingApproval)
    }

    @Test func aHeldCameraAsksBeforeTakingOver() async throws {
        let nikon = integration()
        let held = DiscoveredCamera(ip: "192.168.50.41", name: "Z_8_7000001", source: .heldByAnotherDevice, heldByDeviceName: "Phone B")
        port.onSightings?([held])
        let nearby = NearbyCamera(id: held.id, name: held.displayName, model: "", routes: [.infrastructureNetwork], availability: .unavailable(.busy))
        var iterator = nikon.connect(.nearby(nearby)).makeAsyncIterator()
        guard case .progress(_, .integration(let asked)) = await iterator.next(),
            let prompt = asked as? NikonTakeOverPrompt
        else {
            Issue.record("no take-over prompt")
            return
        }
        #expect(
            prompt.fallbackText == "Phone B is using this camera. Connecting will disconnect it.")
        #expect(port.connects.isEmpty, "nothing dials a held camera before the operator agrees")
        prompt.confirm()
        #expect(await eventually { port.connects == [.discovered(held, takeOver: true)] })

        // Declining ends the attempt without a connect.
        var declined = nikon.connect(.nearby(nearby)).makeAsyncIterator()
        guard case .progress(_, .integration(let again)) = await declined.next(),
            let second = again as? NikonTakeOverPrompt
        else {
            Issue.record("no take-over prompt")
            return
        }
        second.cancel()
        #expect(await declined.next() == nil)
        #expect(port.connects.count == 1)
    }

    /// physical-C C9 (2026-10-19): a ZR never refuses a second initiator, it hands the session over
    /// and drops the phone holding it, so the saved connect must ask before its first dial.
    @Test func aSavedSetupAnotherDeviceHoldsAsksBeforeDialing() async throws {
        port.holder = "Phone B"
        let nikon = integration()
        let camera = try #require(NikonSavedRecordsV0.cameras(from: Self.records).first)
        let route = try #require(camera.routes.first { $0.kind == .infrastructureNetwork })
        let events = nikon.connect(.saved(camera, route: route.id))
        var iterator = events.makeAsyncIterator()
        guard case .progress(_, .integration(let asked)) = await iterator.next(),
            let prompt = asked as? NikonTakeOverPrompt
        else {
            Issue.record("a held saved setup must ask before it contacts the camera")
            return
        }
        #expect(port.holderQueries == ["192.168.50.23"])
        #expect(prompt.holder == "Phone B")
        #expect(port.connects.isEmpty, "nothing dials the camera before the operator agrees")
        prompt.confirm()
        #expect(await eventually { port.connects.count == 1 })
        #expect(port.consentedRequests == [.saved(host: "192.168.50.23", path: .infrastructure)])
    }

    @Test func cancellingTheSavedTakeOverLeavesTheHolderAlone() async throws {
        port.holder = ""
        let nikon = integration()
        let camera = try #require(NikonSavedRecordsV0.cameras(from: Self.records).first)
        let route = try #require(camera.routes.first { $0.kind == .infrastructureNetwork })
        let events = nikon.connect(.saved(camera, route: route.id))
        var iterator = events.makeAsyncIterator()
        guard case .progress(_, .integration(let asked)) = await iterator.next(),
            let prompt = asked as? NikonTakeOverPrompt
        else {
            Issue.record("an unnamed holder still asks")
            return
        }
        #expect(prompt.holder == nil)
        prompt.cancel()
        #expect(await iterator.next() == nil)
        #expect(port.connects.isEmpty && port.consentedRequests.isEmpty, "Cancel never dials")
    }

    @Test func aSavedSetupNobodyHoldsDialsWithoutAsking() async throws {
        let nikon = integration()
        let camera = try #require(NikonSavedRecordsV0.cameras(from: Self.records).first)
        let route = try #require(camera.routes.first { $0.kind == .infrastructureNetwork })
        let events = nikon.connect(.saved(camera, route: route.id))
        #expect(await eventually { port.connects.count == 1 })
        #expect(port.holderQueries == ["192.168.50.23"] && port.consentedRequests.isEmpty)
        withExtendedLifetime(events) {}
    }

    @Test func aHeldSavedSetupUsesTheSameConsentPrompt() async throws {
        let nikon = integration()
        let camera = try #require(NikonSavedRecordsV0.cameras(from: Self.records).first)
        let route = try #require(camera.routes.first { $0.kind == .infrastructureNetwork })
        let events = nikon.connect(.saved(camera, route: route.id))
        #expect(await eventually { port.connects.count == 1 })
        port.finish(
            .failure(
                ConnectionFailure(
                    reason: .heldElsewhere, title: "Camera in use",
                    message: "Phone B is using this camera. Connecting will disconnect it.",
                    actions: [.retry], code: "SIMULATED.held")))
        var iterator = events.makeAsyncIterator()
        guard case .progress(_, .integration(let asked)) = await iterator.next(),
            let prompt = asked as? NikonTakeOverPrompt
        else {
            Issue.record(
                "a held saved setup must ask in the integration prompt before a consented retry")
            return
        }
        #expect(
            prompt.fallbackText == "Phone B is using this camera. Connecting will disconnect it.")
        #expect(port.connects.count == 1, "the held attempt cannot retry until the operator agrees")
        prompt.cancel()
        #expect(await iterator.next() == nil)
        #expect(port.connects.count == 1, "declining never retries")
    }

    @Test func savedConsentIsOnceOnlyAndAConfirmedFailureCannotAskAgain() async throws {
        let nikon = integration()
        let camera = try #require(NikonSavedRecordsV0.cameras(from: Self.records).first)
        let route = try #require(camera.routes.first { $0.kind == .infrastructureNetwork })
        var iterator = nikon.connect(.saved(camera, route: route.id)).makeAsyncIterator()
        #expect(await eventually { port.connects.count == 1 })
        let held = ConnectionFailure(
            reason: .heldElsewhere, title: "Camera in use",
            message: "Phone B is using this camera.",
            actions: [.retry], code: "SIMULATED.held")
        port.finish(.failure(held))
        guard case .progress(_, .integration(let asked)) = await iterator.next(),
            let prompt = asked as? NikonTakeOverPrompt
        else {
            Issue.record("missing saved consent prompt")
            return
        }
        prompt.confirm()
        prompt.confirm()
        #expect(await eventually { port.connects.count == 2 })
        #expect(port.consentedRequests == [.saved(host: "192.168.50.23", path: .infrastructure)])
        port.finish(.failure(held))
        guard case .failed(let failure) = await iterator.next()
        else {
            Issue.record("confirmed failure must end rather than ask for consent again")
            return
        }
        #expect(failure.reason == .heldElsewhere)
        #expect(await iterator.next() == nil)
        prompt.confirm()
        #expect(port.connects.count == 2)
    }

    @Test func replacingASavedAttemptRetiresItsUnansweredConsent() async throws {
        let nikon = integration()
        let camera = try #require(NikonSavedRecordsV0.cameras(from: Self.records).first)
        let route = try #require(camera.routes.first { $0.kind == .infrastructureNetwork })
        var iterator = nikon.connect(.saved(camera, route: route.id)).makeAsyncIterator()
        #expect(await eventually { port.connects.count == 1 })
        port.finish(
            .failure(
                ConnectionFailure(
                    reason: .heldElsewhere, title: "Camera in use", message: "Consent required",
                    actions: [.retry], code: "SIMULATED.held")))
        guard case .progress(_, .integration(let asked)) = await iterator.next(),
            let prompt = asked as? NikonTakeOverPrompt
        else {
            Issue.record("missing saved consent prompt")
            return
        }
        let replacement = nikon.connect(.saved(camera, route: route.id))
        #expect(await iterator.next() == nil)
        #expect(await eventually { port.connects.count == 2 })
        prompt.confirm()
        #expect(port.consentedRequests.isEmpty)
        #expect(port.connects.count == 2)
        port.finish(.failure(CancellationError()))
        for await _ in replacement {}
    }

    @Test func cancellingASavedAttemptRetiresItsUnansweredConsent() async throws {
        let nikon = integration()
        let camera = try #require(NikonSavedRecordsV0.cameras(from: Self.records).first)
        let route = try #require(camera.routes.first { $0.kind == .infrastructureNetwork })
        let events = nikon.connect(.saved(camera, route: route.id))
        var received: NikonTakeOverPrompt?
        let consumer = Task {
            for await event in events {
                if case .progress(_, .integration(let asked)) = event {
                    received = asked as? NikonTakeOverPrompt
                }
            }
        }
        defer { consumer.cancel() }
        #expect(await eventually { port.connects.count == 1 })
        port.finish(
            .failure(
                ConnectionFailure(
                    reason: .heldElsewhere, title: "Camera in use", message: "Consent required",
                    actions: [.retry], code: "SIMULATED.held")))
        #expect(await eventually { received != nil })
        let prompt = try #require(received)
        consumer.cancel()
        await consumer.value
        #expect(await eventually { port.cancels == 1 })
        prompt.confirm()
        #expect(port.consentedRequests.isEmpty && port.connects.count == 1)
    }

    @Test func aLegacyPortKeepsItsAdmissionThroughTheConfirmedOverload() async {
        let legacy = LegacyNikonPort()
        let request = NikonConnectRequest.saved(host: "SIMULATED-host", path: .infrastructure)
        do {
            _ = try await legacy.connect(request, takingOverConfirmed: true)
            Issue.record("legacy admission was bypassed")
        } catch {
            #expect(error as? ConnectionFailure == legacy.failure)
        }
        #expect(legacy.requests == [request])
    }

    @Test func failuresAreTyped() {
        let busy = NikonIntegration.failure(NativeCameraSessionError.initFailed(.busy), message: nil)
        #expect(busy.reason == .heldElsewhere && busy.actions == [.retry])
        #expect(busy.message == NativeCameraSessionError.initFailed(.busy).errorDescription)
        let denied = NikonIntegration.failure(NativeCameraSessionError.localNetworkPermissionDenied, message: "Allow Local Network")
        #expect(denied.reason == .permission(.localNetwork) && denied.actions == [.openSettings, .retry])
        #expect(denied.message == "Allow Local Network" && denied.code == "org.opencapture.nikon-ptp.local-network.denied")
        #expect(NikonIntegration.failure(CocoaError(.fileNoSuchFile), message: "x").reason == .other)
    }

    @Test func aRefusedWiFiJoinKeepsTheSharedCopyAndSettingsFallback() {
        // The host's own message (often the platform's developer text) never replaces the shared copy.
        let refusal = CameraHotspotJoinRefusal(code: 8, network: "Z_6002199")
        let failure = NikonIntegration.failure(refusal, message: "internal error.")
        #expect(failure == refusal.failure(integration: NikonCameraSession.integration))
        #expect(failure.reason == .joinFailed && failure.actions == [.openSettings, .retry])
        #expect(failure.message.contains("Z_6002199") && !failure.message.contains("internal error"))
        #expect(failure.code == "org.opencapture.nikon-ptp.error.connection.wifi-join.code8")
        let declined = NikonIntegration.failure(CameraHotspotJoinRefusal(code: 7, network: "Z_6002199"), message: nil)
        #expect(declined.reason == .cancelled && declined.actions == [.retry])
    }

    @Test func droppingTheAttemptCancelsTheFunnel() async throws {
        let nikon = integration()
        let camera = try #require(NikonSavedRecordsV0.cameras(from: Self.records).last)
        let consumer = Task { for await _ in nikon.connect(.saved(camera, route: camera.routes[0].id)) {} }
        #expect(await eventually { port.connects.count == 1 })
        consumer.cancel()
        await consumer.value
        #expect(await eventually { port.cancels == 1 })
    }

    @Test func replacingBeforeTheTaskStartsDoesNotConnectTheOldCamera() async throws {
        let nikon = integration()
        let cameras = NikonSavedRecordsV0.cameras(from: Self.records)
        let old = try #require(cameras.first)
        let replacement = try #require(cameras.last)
        let previous = nikon.connect(.saved(old, route: old.routes[0].id))
        let current = nikon.connect(.saved(replacement, route: replacement.routes[0].id))
        let expected = NikonConnectRequest.saved(host: "172.20.10.3", path: .phoneHotspot)
        #expect(await eventually { port.connects.last == expected })
        #expect(port.connects == [expected])
        port.finish(.success(NikonConnection(session: FakeCameraSession.nikonLike(), host: "172.20.10.3", path: .phoneHotspot)))
        let (_, _, end) = await outcome(current)
        guard case .connected(let camera) = end else {
            Issue.record("not connected")
            return
        }
        #expect(camera.saved.id == replacement.id)
        let (_, _, oldEnd) = await outcome(previous)
        #expect(oldEnd == nil)
    }

    @Test func forgetHandsTheAppEverySetupHost() async throws {
        let nikon = integration()
        let camera = try #require(NikonSavedRecordsV0.cameras(from: Self.records).first)
        await nikon.forget(camera)
        #expect(port.forgotten == [["192.168.50.23", "192.168.1.1"]])
        #expect(
            nikon.profiles.first?.addableRoutes == [
                .cameraAccessPoint, .infrastructureNetwork, .phoneHotspot, .usb,
            ])
    }
}

@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<10_000 where !condition() { await Task.yield() }
    return condition()
}

@MainActor private final class IntegrationMediaMarker: CameraMediaService {
    let sessionID: CameraSessionID
    init(sessionID: CameraSessionID) { self.sessionID = sessionID }
    func openBrowse() async throws -> any CameraMediaBrowse { throw MediaServiceError.unavailable }
}

/// physical-C C9/C10: the phone that lost the camera must not take it straight back.
@MainActor @Test func takeOverRecoveryAsksTwiceOnlyBeforeTheFirstAttempt() async {
    var asks = 0
    var answers: [String?] = [nil, "Phone B"]
    let first = await NikonTakeOverRecovery.holder(beforeAttempt: 1) {
        asks += 1
        return answers.removeFirst()
    }
    #expect(first == "Phone B" && asks == 2)
    asks = 0
    let later = await NikonTakeOverRecovery.holder(beforeAttempt: 2) {
        asks += 1
        return nil
    }
    #expect(later == nil && asks == 1)
}

/// Hardware pass 4.1: the device that took the camera answers presence only once its session is
/// up, after the body already dropped this one. Two back-to-back sweeps can both land before that
/// answer, so the first attempt keeps asking, spaced, before it may dial.
@MainActor @Test func takeOverRecoveryKeepsAskingOverASpacedWindowBeforeTheFirstAttempt() async {
    var answers: [String?] = [nil, nil, "Phone B"]
    var pauses: [Duration] = []
    let holder = await NikonTakeOverRecovery.holder(
        beforeAttempt: 1, pause: { pauses.append($0) }, lookup: { answers.removeFirst() })
    #expect(holder == "Phone B")
    #expect(
        pauses == Array(
            repeating: NikonTakeOverRecovery.firstAttemptAskSpacing,
            count: NikonTakeOverRecovery.firstAttemptAsks - 1))
    #expect(NikonTakeOverRecovery.firstAttemptAsks >= 3)

    var asks = 0
    let none = await NikonTakeOverRecovery.holder(
        beforeAttempt: 1, pause: { _ in },
        lookup: {
            asks += 1
            return nil
        })
    #expect(none == nil && asks == NikonTakeOverRecovery.firstAttemptAsks)
}
