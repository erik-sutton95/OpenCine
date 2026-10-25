import Foundation
import MonitorPresentation
import OpenCineAppKit
import OpenCineCore
import OpenCineCoreTestSupport
import Testing

@MainActor
private final class ConsentAdmissions { var count = 0 }

private struct TestConfirmationPrompt: ConfirmationPrompt {
    let confirmationID = UUID().uuidString
    let confirmationTitle = "Continue?"
    let fallbackText = "Another operator loses their session."
    let confirmTitle = "Continue"
    let cancelTitle = "Cancel"
    var confirm: @MainActor @Sendable () -> Void
    var cancel: @MainActor @Sendable () -> Void = {}
}

/// The shared connection model against scripted integrations. Kotlin mirror: `CamerasModelTest`,
/// same method names.
@MainActor
@Suite struct CamerasModelTests {
    let fake = FakeIntegration(id: IntegrationID("test.cameras"))
    let listening = FakeIntegration(id: IntegrationID("test.listening"), discoveryModes: [.passive])
    let defaults = Defaults([:])

    static let ap = SavedRoute(key: "ap", kind: .cameraAccessPoint, network: "CAM-1", bluetooth: true)
    static let wifi = SavedRoute(key: "wifi", kind: .infrastructureNetwork, network: "studio", bluetooth: true)
    static let camera = SavedCamera(
        id: "camera-1", integration: IntegrationID("test.cameras"), advertisedName: "CAM-1", model: "Test Body",
        routes: [ap, wifi], preferredRoute: ap.id, lastConnected: Date(timeIntervalSince1970: 1_000))
    static let sighting = NearbyCamera(id: "n2", name: "CAM-2", model: "Test Body", routes: [.cameraAccessPoint])
    static let failure = ConnectionFailure(
        reason: .permission(.bluetooth), phase: .link, title: "Bluetooth is off",
        message: "Turn on Bluetooth for this app.", actions: [.openSettings, .editRoute(wifi.id), .retry],
        code: "test.bluetooth.denied")

    @available(macOS 14, *)
    func model(saved: [SavedCamera] = [camera]) -> CamerasModel {
        let store = SavedCamerasStore(document: defaults.at("document"))
        store.save(saved)
        return CamerasModel(
            integrations: [AppIntegration(fake), AppIntegration(listening)], store: store)
    }

    @available(macOS 14, *)
    @Test func aNeutralPromptReachesOneConsumedShellConsent() async {
        let model = model()
        let admissions = ConsentAdmissions()
        let prompt = TestConfirmationPrompt(confirm: { admissions.count += 1 })
        model.connect(Self.camera)
        fake.attempts[0].progress(.negotiating, step: 0, prompt: .integration(prompt))
        #expect(await eventually { model.consent.pending?.title == "Continue?" })
        model.consent.confirm(prompt.confirmationID)
        fake.attempts[0].progress(.negotiating, step: 1, prompt: .integration(prompt))
        #expect(await eventually { model.attempts[Self.camera.id]?.progress?.current == 1 })
        model.consent.confirm(prompt.confirmationID)
        #expect(admissions.count == 1)
        #expect(model.consent.pending == nil)
    }

    @available(macOS 14, *)
    @Test func retiringTheModelAttemptInvalidatesItsShellConsent() async {
        let model = model()
        let admissions = ConsentAdmissions()
        let prompt = TestConfirmationPrompt(confirm: { admissions.count += 1 })
        model.connect(Self.camera)
        fake.attempts[0].progress(.negotiating, step: 0, prompt: .integration(prompt))
        #expect(await eventually { model.consent.pending != nil })
        model.cancel(Self.camera.id)
        model.consent.confirm(prompt.confirmationID)
        #expect(admissions.count == 0 && model.consent.pending == nil)
    }

    @available(macOS 14, *)
    @Test func camerasDiscoverPassively() async {
        let model = model()
        #expect(fake.liveDiscoveries == [.passive] && listening.liveDiscoveries == [.passive])
        #expect(model.scanning)
        fake.publish([Self.sighting])
        #expect(await eventually { model.nearby.map(\.id) == ["n2"] })
        #expect(model.nearby[0].integration == fake.id)
    }

    @available(macOS 14, *)
    @Test func aBlockedDiscoveryDoesNotClaimToScan() async {
        let blocked = FakeIntegration(
            id: IntegrationID("test.blocked"), discoveryModes: [.passive], discoveryRunning: false)
        let store = SavedCamerasStore(document: Defaults([:]).at("document"))
        let model = CamerasModel(integrations: [AppIntegration(blocked)], store: store)
        #expect(await eventually { !model.scanning })
    }

    @available(macOS 14, *)
    @Test func thePairPageDiscoversActively() async {
        let model = model()
        model.beginPairing()
        #expect(await eventually { fake.liveDiscoveries == [.active] })
        #expect(fake.discoveries == [.passive, .active])
        #expect(listening.liveDiscoveries == [.passive] && listening.discoveries == [.passive])
        model.endPairing()
        #expect(await eventually { fake.liveDiscoveries == [.passive] })
        #expect(fake.discoveries == [.passive, .active, .passive])
    }

    @available(macOS 14, *)
    @Test func discoveryStopsWhileAttemptingOrLive() async {
        let model = model()
        model.connect(Self.camera)
        #expect(await eventually { fake.liveDiscoveries.isEmpty && listening.liveDiscoveries.isEmpty })
        #expect(!model.scanning)
        fake.attempts[0].connect(session: FakeCameraSession.lunaLike())
        #expect(await eventually { model.connected != nil })
        #expect(model.attempts.isEmpty && fake.liveDiscoveries.isEmpty)
        model.sessionEnded()
        #expect(await eventually { fake.liveDiscoveries == [.passive] })
        #expect(model.scanning)
    }

    @available(macOS 14, *)
    @Test func aReachableRouteBeatsThePreferredOneOnlyWhenTheAppPrefersIt() async {
        // The camera prefers its access point; a sighting reaches it over Wi-Fi.
        let reaching = NearbyCamera(
            id: "n1", savedID: Self.camera.id, name: "CAM-1", model: "Test Body", routes: [.infrastructureNetwork],
            routeKey: Self.wifi.key)
        for (policy, expected) in [
            (CamerasModel.RoutePolicy.preferred, Self.ap), (.preferReachable, Self.wifi),
        ] {
            let fake = FakeIntegration(id: IntegrationID("test.cameras"))
            let store = SavedCamerasStore(document: Defaults([:]).at("document"))
            store.save([Self.camera])
            let model = CamerasModel(integrations: [AppIntegration(fake)], store: store, routePolicy: policy)
            #expect(model.defaultRoute(of: Self.camera) == Self.ap.id)
            fake.publish([reaching])
            #expect(await eventually { !model.nearby.isEmpty })
            #expect(CamerasMapping.paired(model)[0].setups.filter(\.isActive).map(\.id) == [expected.id.description])
            model.connect(Self.camera)
            #expect(fake.attempts.map(\.target) == [.saved(Self.camera, route: expected.id)])
        }
    }

    @available(macOS 14, *)
    @Test func oneAttemptPerCamera() async {
        let model = model()
        model.connect(Self.camera)
        let a = fake.attempts[0]
        a.progress(.awaitingApproval, step: 1)
        model.connect(Self.camera, route: Self.wifi.id)
        let b = fake.attempts[1]
        b.progress(.link, step: 0)
        #expect(await eventually { model.attempts["camera-1"]?.progress?.attempt == b.id })
        #expect(a.end != nil && b.end == nil && model.attempts.count == 1)
        #expect(model.attempts["camera-1"]?.progress?.phase == .link)
        #expect(model.attempts["camera-1"]?.route == Self.wifi.id)
        a.progress(.negotiating, step: 3)
        b.progress(.joiningNetwork, step: 2)
        #expect(await eventually { model.attempts["camera-1"]?.progress?.phase == .joiningNetwork })
        #expect(model.attempts["camera-1"]?.progress?.attempt == b.id)
    }

    @available(macOS 14, *)
    @Test func cancelEndsTheAttempt() async {
        let model = model()
        model.connect(Self.camera)
        model.cancel("camera-1")
        #expect(model.attempts.isEmpty)
        #expect(await eventually { fake.attempts[0].end == .cancelled && fake.liveDiscoveries == [.passive] })
    }

    @available(macOS 14, *)
    @Test func failuresOfferTheirActions() async throws {
        let model = model()
        model.connect(Self.camera, route: Self.wifi.id)
        fake.attempts[0].fail(Self.failure)
        #expect(await eventually { model.failures["camera-1"]?.failure == Self.failure })
        #expect(model.attempts.isEmpty)
        #expect(model.perform(.openSettings, for: "camera-1") == .openSettings)
        #expect(model.perform(.editRoute(Self.wifi.id), for: "camera-1") == .editRoute(Self.camera, Self.wifi.id))
        #expect(model.perform(.retry, for: "camera-1") == nil)
        #expect(fake.attempts.count == 2 && fake.attempts[1].target == .saved(Self.camera, route: Self.wifi.id))
        #expect(model.failures.isEmpty && model.attempts["camera-1"] != nil)
    }

    static let localNetworkDenied = ConnectionFailure(
        reason: .permission(.localNetwork), phase: .negotiating, title: "Couldn't connect",
        message: "Local Network access is off. Enable it in Settings, then connect again.",
        actions: [.openSettings, .retry], code: "test.local-network.denied")

    /// Hardware pass 8.0 (Insta iOS 81, Luna Ultra): the link named a Local Network denial while
    /// the system prompt was still up, and the pair page kept it after the operator tapped Allow
    /// until the app was relaunched. A Local Network failure is re-checked by connecting again;
    /// the shell asks for that each time the app becomes active (the prompt or Settings closed).
    @available(macOS 14, *)
    @Test func localNetworkFailuresConnectAgainWhenRechecked() async throws {
        let model = model(saved: [])
        fake.publish([Self.sighting])
        model.beginPairing()
        #expect(await eventually { !model.nearby.isEmpty })
        model.selection = "n2"
        model.connect(try #require(model.nearby.first))
        fake.attempts[0].fail(Self.localNetworkDenied)
        #expect(await eventually { model.failures["n2"] != nil })
        model.retryLocalNetworkFailures()
        #expect(fake.attempts.count == 2 && fake.attempts[1].target == .nearby(Self.sighting))
        #expect(model.failures.isEmpty && model.attempts["n2"] != nil)
        model.retryLocalNetworkFailures()
        #expect(fake.attempts.count == 2, "a running attempt is never replaced")
    }

    /// A re-check dials the current saved record, never a route forgotten since (CodeRabbit, #262).
    @available(macOS 14, *)
    @Test func aRecheckSkipsAForgottenRoute() async {
        let model = model()
        model.connect(Self.camera, route: Self.wifi.id)
        fake.attempts[0].fail(Self.localNetworkDenied)
        #expect(await eventually { model.failures["camera-1"] != nil })
        model.rename("camera-1", to: "A camera")
        model.retryLocalNetworkFailures()
        #expect(fake.attempts.count == 2)
        #expect(fake.attempts.last?.target == .saved(model.saved[0], route: Self.wifi.id), "the current record")
        fake.attempts[1].fail(Self.localNetworkDenied)
        #expect(await eventually { model.failures["camera-1"] != nil })
        model.forgetRoute(Self.wifi.id, of: "camera-1")
        model.retryLocalNetworkFailures()
        #expect(fake.attempts.count == 2, "the forgotten route is not dialled")
    }

    @available(macOS 14, *)
    @Test func otherFailuresWaitForTheOperatorWhenRechecked() async {
        let model = model()
        model.connect(Self.camera)
        fake.attempts[0].fail(Self.failure)
        #expect(await eventually { model.failures["camera-1"] != nil })
        model.retryLocalNetworkFailures()
        #expect(fake.attempts.count == 1 && model.failures["camera-1"]?.failure == Self.failure)
    }

    @available(macOS 14, *)
    @Test func promptsReachTheCardAndThePairPage() async throws {
        let model = model(saved: [])
        fake.publish([Self.sighting])
        model.beginPairing()
        #expect(await eventually { !model.nearby.isEmpty })
        model.selection = "n2"
        model.connect(try #require(model.nearby.first))
        fake.attempts[0].progress(.awaitingApproval, step: 1, prompt: .approveOnCamera("Tap Allow on the camera"))
        #expect(await eventually { model.attempts["n2"]?.prompt?.text == "Tap Allow on the camera" })
        let pairing = CamerasMapping.pairing(model)
        #expect(pairing.currentStep == 2 && pairing.title == "Approve")
        #expect(pairing.instructions == [.init(title: "On the camera", icon: .camera, lines: ["Tap Allow on the camera"])])
        #expect(pairing.progress == "Approve" && pairing.backAction == "Cancel")
    }

    @available(macOS 14, *)
    @Test func connectingUpsertsTheSavedRecord() async throws {
        let model = model()
        var connected: [String] = []
        model.onConnected = { connected.append($0.saved.id) }
        fake.publish([Self.sighting])
        #expect(await eventually { !model.nearby.isEmpty })
        model.connect(try #require(model.nearby.first))
        fake.attempts[0].connect(session: FakeCameraSession.lunaLike())
        #expect(await eventually { model.connected != nil })
        #expect(model.saved.map(\.id) == ["n2", "camera-1"] && connected == ["n2"])
        model.sessionEnded()

        var again = Self.camera
        again.lastConnected = Date(timeIntervalSince1970: 2_000)
        model.connect(Self.camera)
        fake.attempts[1].connect(session: FakeCameraSession.lunaLike(), saved: again)
        #expect(await eventually { model.saved[1] == again })
        #expect(model.saved.map(\.id) == ["n2", "camera-1"] && model.saved[1] == again)
        let stored = SavedCamerasStore(document: defaults.at("document"))
        stored.load()
        #expect(stored.cameras == model.saved)
    }

    @available(macOS 14, *)
    @Test func forgetCallsTheIntegration() async {
        let model = model()
        await model.forget("camera-1")
        #expect(fake.forgotten == [Self.camera] && model.saved.isEmpty)
    }

    @available(macOS 14, *)
    @Test func renameRouteKeepsItsIdentityAndOtherSetups() {
        let model = model()
        model.renameRoute(Self.wifi.id, of: Self.camera.id, to: "  Stage right ")
        var expected = Self.camera
        expected.routes[1].title = "Stage right"
        #expect(model.saved == [expected])
        #expect(CamerasMapping.paired(model)[0].setups[1].title == "Stage right")
        model.reloadSaved()
        #expect(model.saved == [expected])
        model.renameRoute(ConnectionRouteID(), of: Self.camera.id, to: "Unknown route")
        model.renameRoute(Self.wifi.id, of: "missing", to: "Unknown camera")
        #expect(model.saved == [expected])
        model.renameRoute(Self.wifi.id, of: Self.camera.id, to: " \n ")
        #expect(model.saved == [Self.camera])
        #expect(CamerasMapping.paired(model)[0].setups[1].title == "Wi-Fi · studio")
    }

    @available(macOS 14, *)
    @Test func singleRouteCanBeRenamedAndReset() {
        var camera = Self.camera
        camera.routes = [Self.ap]
        let model = model(saved: [camera])
        model.renameRoute(Self.ap.id, of: camera.id, to: "Rig")
        #expect(model.saved[0].routes[0].title == "Rig")
        #expect(!CamerasMapping.paired(model)[0].setups[0].canForget)
        model.renameRoute(Self.ap.id, of: camera.id, to: nil)
        model.reloadSaved()
        #expect(model.saved == [camera])
    }

    @available(macOS 14, *)
    @Test func setupRenameWaitsUntilConnectionAttemptEnds() {
        let model = model()
        model.connect(Self.camera)
        model.renameRoute(Self.ap.id, of: Self.camera.id, to: "Rig")
        #expect(model.saved == [Self.camera])
        model.cancel(Self.camera.id)
        model.renameRoute(Self.ap.id, of: Self.camera.id, to: "Rig")
        #expect(model.saved[0].routes[0].title == "Rig")
    }

    @available(macOS 14, *)
    @Test func renameAndForgetARoute() {
        let model = model()
        model.rename("camera-1", to: "  A cam ")
        model.forgetRoute(Self.ap.id, of: "camera-1")
        #expect(model.saved[0].name == "A cam" && model.saved[0].routes == [Self.wifi])
        #expect(model.saved[0].preferredRoute == nil)
        model.rename("camera-1", to: " ")
        #expect(model.saved[0].name == nil)
    }

    @available(macOS 14, *)
    @Test func upsertSavesWhatAnIntegrationRemembers() {
        let model = model()
        var stamped = Self.camera
        stamped.preferredRoute = Self.wifi.id
        model.upsert(stamped)
        var added = Self.camera
        added.id = "camera-2"
        model.upsert(added)
        #expect(model.saved.map(\.id) == ["camera-2", "camera-1"])
        #expect(model.saved[1].preferredRoute == Self.wifi.id)
        let reread = SavedCamerasStore(document: defaults.at("document"))
        reread.load()
        #expect(reread.cameras.map(\.id) == ["camera-2", "camera-1"])
    }

    @available(macOS 14, *)
    @Test func reloadMergesWhatTheAppSavedItself() {
        let legacy = Defaults(["records": Data(#"[{"id":"camera-9","advertisedName":"CAM-9","modelName":"Test Body","lastConnectedAt":0}]"#.utf8)])
        let store = SavedCamerasStore(
            document: defaults.at("document"),
            legacy: .init(
                data: legacy.at("records"), codec: BodyRecordsV0(integration: IntegrationID("test.cameras"), dates: .epochMilliseconds),
                source: "records"))
        let model = CamerasModel(integrations: [AppIntegration(fake)], store: store)
        #expect(model.saved.map(\.id) == ["camera-9"])
        legacy.values["records"] = Data(#"[{"id":"camera-9","advertisedName":"CAM-9","modelName":"Test Body","lastConnectedAt":0,"customName":"Nine"}]"#.utf8)
        model.reloadSaved()
        #expect(model.saved.map(\.name) == ["Nine"])
        // A save from the model keeps the app's write.
        model.rename("camera-9", to: "Nine")
        #expect(legacy.writes.isEmpty)
    }
}

/// Yields until `condition` holds, so the model's main-actor tasks catch up while other suites
/// share the main actor. Tests never sleep.
@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<10_000 where !condition() { await Task.yield() }
    return condition()
}
