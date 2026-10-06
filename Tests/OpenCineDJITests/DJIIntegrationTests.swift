import Foundation
import OpenCineCore
import OpenCineCoreTestSupport
import OpenCineDJI
import Testing

/// A scripted DJI connect pipeline: it records scans, connects and forgets, reports stages on
/// demand and holds each connect until the test finishes it. A new connect or a disconnect
/// cancels the one in flight.
@MainActor
final class FakeDJIPort: DJIConnectPort {
    var onSightings: (([DJISighting]) -> Void)?
    var onStage: ((DJIConnectionStage, String?) -> Void)?
    private(set) var scans = 0
    private(set) var scanStops = 0
    private(set) var connects: [(String, DJISetup, Bool)] = []
    private(set) var disconnects = 0
    private(set) var forgotten: [String] = []
    private var pending: CheckedContinuation<DJIConnection, Error>?

    func startScan() { scans += 1 }
    func stopScan() { scanStops += 1 }

    func connect(cameraID: String, setup: DJISetup, restoreAccessPoint: Bool) async throws
        -> DJIConnection
    {
        cancelPending()
        connects.append((cameraID, setup, restoreAccessPoint))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelPending() }
        }
    }

    func finish(_ result: Result<DJIConnection, Error>) {
        let waiter = pending
        pending = nil
        waiter?.resume(with: result)
    }

    func disconnect() {
        disconnects += 1
        cancelPending()
    }

    func forget(cameraID: String) { forgotten.append(cameraID) }

    private func cancelPending() {
        let waiter = pending
        pending = nil
        waiter?.resume(throwing: CancellationError())
    }
}

/// The DJI `CameraIntegration` against a scripted pipeline. Kotlin mirror: `DjiIntegrationTest`,
/// same method names.
/// SIMULATED registration fact; no camera operation or fabricated readiness.
private final class RegisteredDJIService: @unchecked Sendable {}
private struct UnregisteredDJIService: Sendable {}

@MainActor
@Suite struct DJIIntegrationTests {
    let port = FakeDJIPort()
    let when = Date(timeIntervalSince1970: 1_759_307_200)
    static let ap = SavedRoute(
        key: "ap", kind: .cameraAccessPoint, network: "OsmoPocket3-AAAA", bluetooth: true)
    static let wifi = SavedRoute(
        key: "wifi", kind: .infrastructureNetwork, network: "studio", bluetooth: true)
    static let saved = SavedCamera(
        id: "cam-1", integration: DJICameraSessionAdapter.integration,
        advertisedName: "OsmoPocket3-AAAA",
        model: "Osmo Pocket 3", routes: [ap, wifi], preferredRoute: ap.id)
    let pocket = DJISighting(
        id: "cam-1", name: "OsmoPocket3-AAAA", model: CameraModel.resolve(modelId: 0x20, name: nil),
        modelId: 0x20)

    func integration() -> DJIIntegration { DJIIntegration(port: port, now: { [when] in when }) }

    func live() -> Result<DJIConnection, Error> {
        .success(
            DJIConnection(session: FakeCameraSession.djiLike(), joinedNetwork: "OsmoPocket3-AAAA"))
    }

    func outcome(_ events: AsyncStream<ConnectionEvent>) async -> (
        progress: [ConnectionProgress], prompts: [String?], end: ConnectionEvent?
    ) {
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

    @Test func connectedForwardsOptionalServicesAndKeepsSessionOwner() async {
        let dji = integration()
        port.onSightings?([pocket])
        let events = dji.connect(
            .nearby(
                NearbyCamera(
                    id: "cam-1", name: "OsmoPocket3-AAAA",
                    model: "Osmo Pocket 3", routes: [.cameraAccessPoint])))
        #expect(await eventually { port.connects.count == 1 })
        let session = FakeCameraSession.djiLike()
        let service = RegisteredDJIService()
        var services = CameraServices()
        services.register(service, as: RegisteredDJIService.self)
        port.finish(.success(DJIConnection(session: session, services: services)))
        guard case .connected(let camera) = await outcome(events).end else {
            Issue.record("not connected")
            return
        }
        #expect(camera.session.id == session.id)
        #expect(camera.services[RegisteredDJIService.self] === service)
        #expect(camera.services[UnregisteredDJIService.self] == nil)
    }

    @Test func legacyConnectionKeepsOptionalServicesAbsent() async {
        let dji = integration()
        port.onSightings?([pocket])
        let events = dji.connect(
            .nearby(
                NearbyCamera(
                    id: "cam-1", name: "OsmoPocket3-AAAA",
                    model: "Osmo Pocket 3", routes: [.cameraAccessPoint])))
        #expect(await eventually { port.connects.count == 1 })
        port.finish(live())
        guard case .connected(let camera) = await outcome(events).end else {
            Issue.record("not connected")
            return
        }
        #expect(camera.services[RegisteredDJIService.self] == nil)
    }

    @Test func discoveryListensPassivelyOverBluetooth() async {
        let dji = integration()
        var active = 0
        for await _ in dji.discover(.active) { active += 1 }
        #expect(active == 0)
        let lists = dji.discover(.passive)
        var iterator = lists.makeAsyncIterator()
        #expect(await iterator.next() == [])
        port.onSightings?([pocket])
        #expect(await iterator.next()?.map(\.name) == ["OsmoPocket3-AAAA"])
        #expect(port.scans == 1 && port.connects.isEmpty, "listening never connects")
        let consumer = Task { for await _ in lists {} }
        consumer.cancel()
        await consumer.value
        #expect(await eventually { port.scanStops == 1 })
        #expect(
            dji.profiles.contains {
                $0.title == "Osmo Pocket 3"
                    && $0.addableRoutes == [.infrastructureNetwork, .phoneHotspot]
            })
        #expect(!dji.profiles.contains { $0.title.contains("Mavic") }, "drones are not listed")
    }

    @Test func cameraWiFiStepsAndPrompts() async throws {
        let dji = integration()
        port.onSightings?([pocket])
        let events = dji.connect(
            .nearby(
                NearbyCamera(
                    id: "cam-1", name: "OsmoPocket3-AAAA", model: "Osmo Pocket 3",
                    routes: [.cameraAccessPoint])))
        #expect(await eventually { port.connects.count == 1 })
        #expect(port.connects[0].1 == .cameraWiFi && !port.connects[0].2)
        for stage in [
            DJIConnectionStage.connectingBluetooth, .pairing, .awaitingApproval, .readingWiFi, .joiningWiFi,
            .openingDatalink,
        ] {
            port.onStage?(stage, nil)
        }
        port.finish(live())
        let (progress, prompts, end) = await outcome(events)
        // The Wi-Fi step's caption is the phase label main showed when the app reports no progress.
        #expect(
            progress.map { "\($0.phase) \($0.current) \($0.note ?? "-")" } == [
                "link 0 -", "awaitingApproval 0 -", "link 1 Reading Wi-Fi credentials…",
                "joiningNetwork 1 Joining camera Wi-Fi…", "negotiating 2 -",
            ])
        #expect(prompts == [nil, "Approve on the camera", nil, nil, nil])
        #expect(
            progress[0].steps.map(\.title) == [
                "Connecting over Bluetooth", "Joining camera Wi-Fi", "Opening the video link",
                "Starting the picture",
            ])
        guard case .connected(let camera) = end else {
            Issue.record("not connected")
            return
        }
        #expect(
            camera.saved.id == "cam-1" && camera.saved.lastConnected == when
                && camera.saved.extras == ["modelId": "32"])
        #expect(
            camera.saved.routes.count == 1 && camera.saved.routes[0].network == "OsmoPocket3-AAAA")
        #expect(camera.saved.preferredRoute == camera.saved.routes[0].id)
    }

    @Test func aWiFiSetupMovesTheCamera() async {
        let dji = integration()
        let events = dji.connect(.saved(Self.saved, route: Self.wifi.id))
        #expect(await eventually { port.connects.count == 1 })
        #expect(port.connects[0].1 == .wifi(network: "studio", password: nil))
        port.onStage?(.findingCamera, "Finding the camera on studio")
        port.finish(
            .failure(
                ConnectionFailure(
                    reason: .credentialsRejected, title: "t",
                    message: "The camera could not join the Wi-Fi.", actions: [.retry],
                    code: "c")))
        let (progress, _, end) = await outcome(events)
        #expect(
            progress.last?.steps.map(\.title) == [
                "Connecting over Bluetooth", "Moving the camera to studio", "Finding the camera",
                "Starting the picture",
            ])
        #expect(
            progress.last?.current == 2 && progress.last?.note == "Finding the camera on studio")
        guard case .failed(let failure) = end else {
            Issue.record("not failed")
            return
        }
        #expect(
            failure.reason == .credentialsRejected
                && failure.title == "Couldn’t connect over studio")
        #expect(failure.actions == [.editRoute(Self.wifi.id), .retry, .useRoute(Self.ap.id)])
        #expect(failure.phase == .joiningNetwork)
    }

    @Test func addingARouteSavesTheNetworkFirst() async {
        let dji = integration()
        let draft = RouteDraft(kind: .phoneHotspot, network: "phone", secret: "hunter22")
        let events = dji.connect(.addRoute(Self.saved, draft))
        #expect(await eventually { port.connects.count == 1 })
        #expect(port.connects[0].1 == .phoneHotspot(network: "phone", password: "hunter22"))
        port.finish(live())
        let (_, _, end) = await outcome(events)
        guard case .connected(let camera) = end else {
            Issue.record("not connected")
            return
        }
        #expect(camera.saved.routes.map(\.key) == ["ap", "wifi", "hotspot"])
        #expect(
            camera.saved.routes.last?.network == "phone"
                && camera.saved.preferredRoute == camera.saved.routes.last?.id)
        #expect(
            camera.saved.routes[0].network == "OsmoPocket3-AAAA",
            "a moving setup keeps the camera's own network name")
    }

    @Test func typedFailuresKeepTheirCopy() async {
        let dji = integration()
        let events = dji.connect(.saved(Self.saved, route: Self.ap.id))
        #expect(await eventually { port.connects.count == 1 })
        port.onStage?(.awaitingApproval, nil)
        port.finish(.failure(URLError(.timedOut)))
        let (_, _, end) = await outcome(events)
        guard case .failed(let failure) = end else {
            Issue.record("not failed")
            return
        }
        #expect(failure.reason == .other && failure.phase == .awaitingApproval)
        #expect(
            failure.message == URLError(.timedOut).localizedDescription
                && failure.actions == [.retry])
        #expect(failure.code == "org.opencapture.openpocketcine.dji.connect.failed")
    }

    @Test func cancellingTheConsumerDisconnects() async {
        let dji = integration()
        let events = dji.connect(.saved(Self.saved, route: Self.ap.id))
        #expect(await eventually { port.connects.count == 1 })
        let consumer = Task { for await _ in events {} }
        consumer.cancel()
        await consumer.value
        #expect(await eventually { port.disconnects == 1 })
    }

    @Test func aNewerAttemptEndsTheOlder() async {
        let dji = integration()
        let older = dji.connect(.saved(Self.saved, route: Self.ap.id))
        #expect(await eventually { port.connects.count == 1 })
        var replacement = Self.saved
        replacement.id = "cam-2"
        let newer = dji.connect(.saved(replacement, route: Self.ap.id))
        #expect(await eventually { port.connects.count == 2 })
        port.onStage?(.awaitingApproval, nil)
        port.finish(live())
        let (olderProgress, _, olderEnd) = await outcome(older)
        #expect(olderEnd == nil, "the older attempt ends without an outcome")
        #expect(olderProgress.isEmpty)
        let (_, _, end) = await outcome(newer)
        guard case .connected(let camera) = end else {
            Issue.record("not connected")
            return
        }
        #expect(camera.saved.id == replacement.id)
    }

    @Test func replacingBeforeTheTaskStartsDoesNotConnectTheOldCamera() async {
        let dji = integration()
        let previous = dji.connect(.saved(Self.saved, route: Self.ap.id))
        var replacement = Self.saved
        replacement.id = "cam-2"
        let current = dji.connect(.saved(replacement, route: Self.ap.id))
        #expect(await eventually { port.connects.last?.0 == replacement.id })
        #expect(port.connects.map(\.0) == [replacement.id])
        port.finish(live())
        let (_, _, end) = await outcome(current)
        guard case .connected(let camera) = end else {
            Issue.record("not connected")
            return
        }
        #expect(camera.saved.id == replacement.id)
        let (_, _, oldEnd) = await outcome(previous)
        #expect(oldEnd == nil)
    }

    @Test func forgetDropsTheSavedWiFiOnly() async {
        await integration().forget(Self.saved)
        #expect(port.forgotten == ["cam-1"])
    }

    @Test func aMovingSetupIsRememberedBeforeItMovesTheCamera() async {
        let dji = integration()
        var stored: [SavedCamera] = []
        dji.saveRecord = { stored.append($0) }
        let overAccessPoint = dji.connect(.saved(Self.saved, route: Self.ap.id))
        #expect(await eventually { port.connects.count == 1 })
        #expect(stored.isEmpty, "camera Wi-Fi is remembered only once live")
        let overWiFi = dji.connect(.saved(Self.saved, route: Self.wifi.id))
        #expect(stored.map(\.preferredRoute) == [Self.wifi.id], "stamped before the attempt starts")
        #expect(await eventually { port.connects.count == 2 })
        port.finish(
            .failure(
                ConnectionFailure(
                    reason: .timedOut, title: "t", message: "m", actions: [.retry], code: "c")))
        _ = await outcome(overWiFi)
        _ = await outcome(overAccessPoint)
        #expect(stored.count == 1, "a failed attempt leaves the stamp in place")

        let draft = RouteDraft(kind: .phoneHotspot, network: "phone", secret: "hunter22")
        let adding = dji.connect(.addRoute(Self.saved, draft))
        #expect(
            stored.last?.routes.map(\.key) == ["ap", "wifi", "hotspot"],
            "a route being added is saved first")
        #expect(stored.last?.preferredRoute == stored.last?.routes.last?.id)
        withExtendedLifetime(adding) {}
    }

    @Test func stampingWithoutTheRouteKeepsTheLegacySetup() async {
        var apOnly = Self.saved
        apOnly.routes = [Self.ap]
        let stamped = DJIIntegration.stamping(apOnly, movingTo: .infrastructureNetwork)
        #expect(stamped.preferredRoute == nil && stamped.extras["lastSetup"] == "wifi")
        #expect(DJIIntegration.stamping(apOnly, movingTo: .cameraAccessPoint) == apOnly)
        let dji = integration()
        let events = dji.connect(.saved(stamped, route: Self.ap.id))
        #expect(await eventually { port.connects.count == 1 })
        #expect(port.connects[0].2, "the scan may have left the camera in station role")
        port.finish(live())
        let (_, _, end) = await outcome(events)
        guard case .connected(let camera) = end else {
            Issue.record("not connected")
            return
        }
        #expect(
            camera.saved.extras["lastSetup"] == nil && camera.saved.preferredRoute == Self.ap.id)
    }

    @Test func anotherCamerasNetworkIsNeverSaved() async {
        let dji = integration()
        var other = Self.saved
        other.id = "cam-2"
        dji.savedCameras = { [other] }
        let nearby = NearbyCamera(
            id: "cam-3", name: "Osmo Pocket 3", model: "Osmo Pocket 3", routes: [.cameraAccessPoint]
        )
        let owned = dji.connect(.nearby(nearby))
        #expect(await eventually { port.connects.count == 1 })
        port.finish(
            .success(
                DJIConnection(
                    session: FakeCameraSession.djiLike(), joinedNetwork: "OsmoPocket3-AAAA",
                    camera: DJISighting(
                        id: "cam-3", name: "OsmoPocket3-CCCC", model: pocket.model, modelId: 0x20)))
        )
        guard case .connected(let first) = await outcome(owned).end else {
            Issue.record("not connected")
            return
        }
        #expect(
            first.saved.routes.map(\.network) == [nil],
            "the other camera's access point is not saved here")
        #expect(
            first.saved.advertisedName == "OsmoPocket3-CCCC"
                && first.saved.extras["modelId"] == "32")

        let nano = DJISighting(
            id: "cam-4", name: "OsmoNano-DDDD",
            model: CameraModel.resolve(modelId: 0x19, name: nil), modelId: 0x19)
        let crossed = dji.connect(
            .nearby(
                NearbyCamera(
                    id: "cam-4", name: "Osmo Nano", model: "Osmo Nano", routes: [.cameraAccessPoint]
                )))
        #expect(await eventually { port.connects.count == 2 })
        port.finish(
            .success(
                DJIConnection(
                    session: FakeCameraSession.djiLike(), joinedNetwork: "OsmoPocket3-EEEE",
                    camera: nano)))
        guard case .connected(let second) = await outcome(crossed).end else {
            Issue.record("not connected")
            return
        }
        #expect(
            second.saved.routes.map(\.network) == [nil],
            "a Pocket network is never saved with a Nano")
    }

    @Test func aRestoredAccessPointFollowsAMovedCamera() async {
        var moved = Self.saved
        moved.preferredRoute = Self.wifi.id
        let events = integration().connect(.saved(moved, route: Self.ap.id))
        #expect(await eventually { port.connects.count == 1 })
        #expect(port.connects[0].2, "the camera may still be in station role")
        withExtendedLifetime(events) {}
    }
}

@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<10_000 where !condition() { await Task.yield() }
    return condition()
}
