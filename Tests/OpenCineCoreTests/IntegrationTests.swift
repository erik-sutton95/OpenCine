import Foundation
import OpenCineCore
import OpenCineCoreTestSupport
import Testing

/// The integration contract (SHELL-02), run against the scripted `FakeIntegration`.
/// Kotlin mirror: `IntegrationContractTest`, same method names.
@MainActor
@Suite struct IntegrationContract {
    let route = SavedRoute(key: "ap", kind: .cameraAccessPoint, network: "CAM-1", bluetooth: true)
    var camera: SavedCamera {
        SavedCamera(
            id: "camera-1", integration: IntegrationID("test.fake-integration"), advertisedName: "CAM-1",
            model: "Test Body", routes: [route])
    }
    let failure = ConnectionFailure(
        reason: .timedOut, phase: .awaitingApproval, title: "Not approved",
        message: "Approve on the camera.", actions: [.retry], code: "test.approval.timeout")

    @Test func discoveryYieldsTheLatestList() async {
        let integration = FakeIntegration()
        let nearby = NearbyCamera(id: "n1", name: "CAM-1", model: "Test Body", routes: [.cameraAccessPoint])
        var lists = integration.discover(.passive).makeAsyncIterator()
        #expect(await lists.next() == [])
        integration.publish([nearby])
        #expect(await lists.next() == [nearby])
    }

    @Test func anUnlistedModeFinishesAtOnce() async {
        let integration = FakeIntegration(discoveryModes: [.passive], endpoints: ["10.0.0.2"])
        var count = 0
        for await _ in integration.discover(.active) { count += 1 }
        #expect(count == 0)
        #expect(integration.discoveries.isEmpty && integration.dials.isEmpty)
    }

    @Test func cancellingDiscoveryStopsIt() async {
        let integration = FakeIntegration()
        let lists = integration.discover(.passive)
        #expect(integration.liveDiscoveries == [.passive])
        let consumer = Task { for await _ in lists {} }
        consumer.cancel()
        await consumer.value
        #expect(integration.liveDiscoveries.isEmpty)
    }

    @Test func aLateEventFromAttemptANeverUpdatesAttemptB() async {
        let integration = FakeIntegration()
        let target = ConnectTarget.saved(camera, route: route.id)
        let streamA = integration.connect(target)
        let a = integration.attempts[0]
        a.progress(.link, step: 0)
        let streamB = integration.connect(target)
        let b = integration.attempts[1]
        a.progress(.awaitingApproval, step: 1)
        a.fail(failure)
        b.progress(.link, step: 0)
        b.connect(session: FakeCameraSession.lunaLike())

        let eventsA = await collect(streamA)
        let eventsB = await collect(streamB)
        #expect(eventsA.map(summary) == ["progress link 0"])
        #expect(eventsA.compactMap(attempt) == [a.id])
        #expect(eventsB.map(summary) == ["progress link 0", "connected camera-1"])
        #expect(eventsB.compactMap(attempt) == [b.id])
        #expect(a.end == .superseded && a.dropped == 2)
        #expect(b.end == .connected)
    }

    @Test func attemptsForDifferentCamerasRunSideBySide() async {
        let integration = FakeIntegration()
        let first = integration.connect(.saved(camera, route: route.id))
        let nearby = NearbyCamera(id: "n2", name: "CAM-2", model: "Test Body", routes: [.cameraAccessPoint])
        let second = integration.connect(.nearby(nearby))
        #expect(integration.attempts.map(\.end) == [nil, nil])
        // Dropping a stream is cancelling its consumer.
        withExtendedLifetime(first) {}
        withExtendedLifetime(second) {}
    }

    @Test func cancellingTheConsumerCancelsTheAttempt() async {
        let integration = FakeIntegration()
        let events = integration.connect(.saved(camera, route: route.id))
        let attempt = integration.attempts[0]
        let consumer = Task { for await _ in events {} }
        consumer.cancel()
        await consumer.value
        #expect(attempt.end == .cancelled)
        attempt.progress(.link, step: 0)
        #expect(attempt.dropped == 1)
    }

    @Test func connectedAndFailedAreTerminal() async {
        let integration = FakeIntegration()
        let first = integration.connect(.saved(camera, route: route.id))
        let connected = integration.attempts[0]
        connected.connect(session: FakeCameraSession.lunaLike())
        connected.progress(.link, step: 0)
        connected.fail(failure)
        #expect(await collect(first).map(summary) == ["connected camera-1"])

        let second = integration.connect(.saved(camera, route: route.id))
        let failed = integration.attempts[1]
        failed.prompt(.approveOnCamera("Approve on the camera"))
        failed.fail(failure)
        failed.connect(session: FakeCameraSession.lunaLike())
        #expect(await collect(second).map(summary) == ["progress awaitingApproval 1 prompt", "failed test.approval.timeout"])
        #expect(connected.dropped == 2 && failed.dropped == 1)
    }

    @Test func aFirstConnectBuildsTheRecordFromTheSighting() async {
        let integration = FakeIntegration()
        let nearby = NearbyCamera(
            id: "n1", name: "CAM-1", model: "Test Body", routes: [.infrastructureNetwork, .cameraAccessPoint])
        let events = integration.connect(.nearby(nearby))
        integration.attempts[0].connect(session: FakeCameraSession.lunaLike())
        guard case .connected(let connected) = await collect(events).last else {
            Issue.record("not connected")
            return
        }
        #expect(connected.saved.id == "n1" && connected.saved.integration == integration.id)
        #expect(connected.saved.routes.map(\.kind) == [.cameraAccessPoint, .infrastructureNetwork])
    }

    @Test func anAttemptHandlerAnswersEveryConnect() async {
        let integration = FakeIntegration()
        integration.onAttempt = { $0.connect(session: FakeCameraSession.lunaLike()) }
        let nearby = NearbyCamera(id: "n1", name: "CAM-1", model: "Test Body", routes: [.cameraAccessPoint])
        #expect(await collect(integration.connect(.nearby(nearby))).map(summary) == ["connected n1"])
        #expect(integration.attempts.map(\.end) == [.connected])
    }

    @Test func forgetReachesTheIntegration() async {
        let integration = FakeIntegration()
        await integration.forget(camera)
        #expect(integration.forgotten == [camera])
    }

    @Test func servicesAreLookedUpByType() {
        var services = CameraServices()
        #expect(services[(any Greeting).self] == nil)
        services.register(English(), as: (any Greeting).self)
        #expect(services[(any Greeting).self]?.hello == "hello")
        #expect(services[English.self] == nil)
    }

    @Test func aDraftNeverPrintsItsSecret() {
        let draft = RouteDraft(kind: .infrastructureNetwork, network: "studio", secret: "hunter2")
        for text in [String(describing: draft), String(reflecting: draft), "\(draft)"] {
            #expect(!text.contains("hunter2") && text.contains("studio"))
        }
    }

    @Test func targetsNameTheirCamera() {
        let sighting = NearbyCamera(id: "n1", name: "CAM-1", model: "Test Body", routes: [])
        #expect(ConnectTarget.saved(camera, route: route.id).cameraID == "camera-1")
        #expect(ConnectTarget.addRoute(camera, RouteDraft(kind: .phoneHotspot)).cameraID == "camera-1")
        #expect(ConnectTarget.nearby(sighting).cameraID == "n1")
        var known = sighting
        known.savedID = "camera-1"
        #expect(ConnectTarget.nearby(known).cameraID == "camera-1")
        #expect(ConnectionPrompt.acceptNetworkJoin(network: "CAM-1", "Tap Join").text == "Tap Join")
    }
}

private protocol Greeting: Sendable { var hello: String { get } }
private struct English: Greeting { let hello = "hello" }

func collect(_ events: AsyncStream<ConnectionEvent>) async -> [ConnectionEvent] {
    var all: [ConnectionEvent] = []
    for await event in events { all.append(event) }
    return all
}

func summary(_ event: ConnectionEvent) -> String {
    switch event {
    case .progress(let progress, let prompt):
        "progress \(progress.phase) \(progress.current)" + (prompt == nil ? "" : " prompt")
    case .connected(let camera): "connected \(camera.saved.id)"
    case .failed(let failure): "failed \(failure.code)"
    }
}

func attempt(_ event: ConnectionEvent) -> ConnectionAttemptID? {
    if case .progress(let progress, _) = event { return progress.attempt }
    return nil
}

extension FakeAttempt {
    func prompt(_ prompt: ConnectionPrompt) { progress(.awaitingApproval, step: 1, prompt: prompt) }
}
