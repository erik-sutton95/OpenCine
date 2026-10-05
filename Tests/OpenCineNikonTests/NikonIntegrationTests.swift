import Foundation
import OpenCineCore
import OpenCineCoreTestSupport
import OpenCineNikon
import OpenCineMedia
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
        #expect(list.map(\.availability) == [.available, .available, .unavailable(.busy), .available])
        #expect(list.map(\.routes) == [[.infrastructureNetwork], [.infrastructureNetwork], [.infrastructureNetwork], [.usb]])
    }

    @Test func connectedServicesPreserveExactInstanceAndDefaultEmpty() async throws {
        let nikon = integration()
        let camera = try #require(NikonSavedRecordsV0.cameras(from: Self.records).first)
        let studio = try #require(camera.routes.first { $0.key == "infrastructure|Studio" })
        let native = FakeCameraSession.nikonLike()
        let marker = IntegrationMediaMarker(sessionID: native.id)
        var services = CameraServices(); services.register(marker, as: (any CameraMediaService).self)
        let defaults = NikonConnection(session: native, host: "192.168.50.23", path: .infrastructure)
        #expect(defaults.services[(any CameraMediaService).self] == nil)
        let events = nikon.connect(.saved(camera, route: studio.id))
        #expect(await eventually { port.connects.count == 1 })
        port.finish(.success(.init(session: native, host: "192.168.50.23", path: .infrastructure, services: services)))
        let (_, _, end) = await outcome(events)
        guard case .connected(let camera) = end else { Issue.record("not connected"); return }
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
        #expect(progress.map { "\($0.phase) \($0.current)" } == ["link 0", "negotiating 1", "negotiating 2"])
        #expect(progress[0].steps.map(\.title) == ["Finding the camera", "Connecting", "Starting live view"])
        #expect(prompts == [nil, nil, nil])
        guard case .connected(let connected) = end else { Issue.record("not connected"); return }
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
        #expect(prompts == [ConnectionProgressCopy.statusDetail(phase: .joiningWiFi, deviceName: "ZR_3001234", friendlyError: nil), nil, "Pairing with code 1234…"])
        guard case .failed(let failure) = end else { Issue.record("not failed"); return }
        #expect(failure.reason == .notApproved && failure.phase == .awaitingApproval)
    }

    @Test func aHeldCameraAsksBeforeTakingOver() async throws {
        let nikon = integration()
        let held = DiscoveredCamera(ip: "192.168.50.41", name: "Z_8_7000001", source: .heldByAnotherDevice, heldByDeviceName: "Phone B")
        port.onSightings?([held])
        let nearby = NearbyCamera(id: held.id, name: held.displayName, model: "", routes: [.infrastructureNetwork], availability: .unavailable(.busy))
        var iterator = nikon.connect(.nearby(nearby)).makeAsyncIterator()
        guard case .progress(_, .integration(let asked)) = await iterator.next(), let prompt = asked as? NikonTakeOverPrompt
        else { Issue.record("no take-over prompt"); return }
        #expect(prompt.fallbackText == "Phone B is using this camera. Connecting will disconnect it.")
        #expect(port.connects.isEmpty, "nothing dials a held camera before the operator agrees")
        prompt.confirm()
        #expect(await eventually { port.connects == [.discovered(held, takeOver: true)] })

        // Declining ends the attempt without a connect.
        var declined = nikon.connect(.nearby(nearby)).makeAsyncIterator()
        guard case .progress(_, .integration(let again)) = await declined.next(), let second = again as? NikonTakeOverPrompt
        else { Issue.record("no take-over prompt"); return }
        second.cancel()
        #expect(await declined.next() == nil)
        #expect(port.connects.count == 1)
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
        guard case .connected(let camera) = end else { Issue.record("not connected"); return }
        #expect(camera.saved.id == replacement.id)
        let (_, _, oldEnd) = await outcome(previous)
        #expect(oldEnd == nil)
    }

    @Test func forgetHandsTheAppEverySetupHost() async throws {
        let nikon = integration()
        let camera = try #require(NikonSavedRecordsV0.cameras(from: Self.records).first)
        await nikon.forget(camera)
        #expect(port.forgotten == [["192.168.50.23", "192.168.1.1"]])
        #expect(nikon.profiles.first?.addableRoutes == [.cameraAccessPoint, .infrastructureNetwork, .phoneHotspot, .usb])
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
