import Foundation
import OpenCineAppKit
import OpenCineCore
import OpenCineCoreTestSupport
import Testing

/// Pairing on a computer: the camera joins the module's camera network, asked for once and reused
/// while its password is kept. SIMULATED integration; nothing reaches a camera or a radio.
@MainActor
@Suite struct CameraNetworkPairingTests {
    typealias T = CamerasModelTests

    /// The app's Keychain stand-in: passwords by network name.
    final class Passwords {
        var byNetwork: [String: String] = [:]
    }

    @available(macOS 14, *)
    func setup(saved: [SavedCamera] = [], current: String? = "Studio", network: String? = nil)
        -> (CamerasModel, FakeIntegration, CameraNetworkPairing, Passwords, CameraNetworkStore)
    {
        let fake = FakeIntegration(id: IntegrationID("test.cameras"))
        let store = SavedCamerasStore(document: Defaults([:]).at("document"))
        store.save(saved)
        let model = CamerasModel(integrations: [AppIntegration(fake)], store: store)
        let defaults = UserDefaults(suiteName: "CameraNetworkPairingTests.\(UUID())")!
        let choice = CameraNetworkStore(defaults: defaults, key: "cameraNetwork")
        if let network { choice.save(.init(network: network)) }
        let passwords = Passwords()
        let pairing = CameraNetworkPairing(
            store: choice, password: { passwords.byNetwork[$0] },
            savePassword: { passwords.byNetwork[$0.ssid] = $0.password }, currentNetwork: { current })
        return (model, fake, pairing, passwords, choice)
    }

    @available(macOS 14, *)
    func sighting(_ model: CamerasModel, _ fake: FakeIntegration, _ camera: NearbyCamera = T.sighting) async throws
        -> CamerasModel.Sighting
    {
        model.beginPairing()
        fake.publish([camera])
        #expect(await eventually { !model.nearby.isEmpty })
        return try #require(model.nearby.first)
    }

    @available(macOS 14, *)
    @Test func aSightingJoinsTheNetworkAsANewRecord() async throws {
        let (model, fake, _, _, _) = setup()
        let draft = RouteDraft(kind: .infrastructureNetwork, network: "Studio", secret: "pass1234")
        model.connect(try await sighting(model, fake), onto: draft)
        #expect(await eventually { !fake.attempts.isEmpty })
        let record = SavedCamera(
            id: "n2", integration: IntegrationID("test.cameras"), advertisedName: "CAM-2", model: "Test Body")
        #expect(fake.attempts[0].target == .addRoute(record, draft))
        #expect(model.attempts["n2"] != nil, "the wizard follows it under the sighting's id")
    }

    @available(macOS 14, *)
    @Test func aSavedCamerasSightingKeepsItsRecord() async throws {
        let (model, fake, _, _, _) = setup(saved: [T.camera])
        let known = NearbyCamera(id: "n1", savedID: "camera-1", name: "CAM-1", model: "Test Body", routes: [.cameraAccessPoint])
        let draft = RouteDraft(kind: .infrastructureNetwork, network: "Studio", secret: "pass1234")
        model.connect(try await sighting(model, fake, known), onto: draft)
        #expect(await eventually { !fake.attempts.isEmpty })
        #expect(fake.attempts[0].target == .addRoute(T.camera, draft))
    }

    @available(macOS 14, *)
    @Test func firstPairingAsksThenJoinsTheChosenNetwork() async throws {
        let (model, fake, pairing, passwords, store) = setup()
        await pairing.pair(try await sighting(model, fake), in: model)
        #expect(pairing.asking == .init(suggested: "Studio"))
        #expect(fake.attempts.isEmpty, "nothing connects before the network is chosen")
        pairing.chose(StationNetwork(ssid: "Studio", password: "pass1234", hotspot: false), in: model)
        #expect(pairing.asking == nil && pairing.network == "Studio" && store.load() == .init(network: "Studio"))
        #expect(passwords.byNetwork["Studio"] == "pass1234", "the password is kept for the next pairing")
        #expect(await eventually { !fake.attempts.isEmpty })
        guard case .addRoute(_, let draft) = fake.attempts[0].target else { Issue.record("not an added setup"); return }
        #expect(draft == RouteDraft(kind: .infrastructureNetwork, network: "Studio", secret: "pass1234"))
    }

    @available(macOS 14, *)
    @Test func aSecondCameraReusesTheNetworkWithoutAsking() async throws {
        let (model, fake, pairing, passwords, store) = setup(current: "Other")
        store.save(.init(network: "Studio"))
        passwords.byNetwork["Studio"] = "pass1234"
        await pairing.pair(try await sighting(model, fake), in: model)
        #expect(pairing.asking == nil)
        #expect(await eventually { !fake.attempts.isEmpty })
        guard case .addRoute(_, let draft) = fake.attempts[0].target else { Issue.record("not an added setup"); return }
        #expect(draft == RouteDraft(kind: .infrastructureNetwork, network: "Studio", secret: "pass1234"))
    }

    @available(macOS 14, *)
    @Test func aSavedNetworkWhosePasswordIsGoneAsksAgain() async throws {
        let (model, fake, pairing, _, store) = setup(current: nil)
        store.save(.init(network: "Studio"))
        await pairing.pair(try await sighting(model, fake), in: model)
        #expect(pairing.asking == .init(suggested: "Studio"))
        #expect(fake.attempts.isEmpty)
    }

    @available(macOS 14, *)
    @Test func changeAppliesToTheNextPairingOnly() async throws {
        // The Mac reads another Wi-Fi name: the next pairing must still reuse the changed network.
        let (model, fake, pairing, passwords, store) = setup(current: "Other", network: "Studio")
        passwords.byNetwork = ["Studio": "pass1234"]
        #expect(pairing.network == "Studio")
        pairing.change()
        #expect(pairing.asking == .init(suggested: "Studio"))
        pairing.chose(StationNetwork(ssid: "Venue", password: "venue123", hotspot: false), in: model)
        #expect(fake.attempts.isEmpty, "a change alone connects nothing")
        #expect(pairing.network == "Venue" && store.load() == .init(network: "Venue"))
        await pairing.pair(try await sighting(model, fake), in: model)
        #expect(await eventually { !fake.attempts.isEmpty })
        guard case .addRoute(_, let draft) = fake.attempts[0].target else { Issue.record("not an added setup"); return }
        #expect(pairing.asking == nil, "the password typed on Change network is kept")
        #expect(draft == RouteDraft(kind: .infrastructureNetwork, network: "Venue", secret: "venue123"))
        pairing.cancel()
        #expect(pairing.asking == nil)
    }
}
