import Foundation
import MonitorPresentation
import OpenCineAppKit
import OpenCineCore
import OpenCineCoreTestSupport
import Testing

/// Golden values for what the shared pages show. Kotlin mirror: `CamerasMappingTest`, same
/// method names and values.
@MainActor
@Suite struct CamerasMappingTests {
    typealias T = CamerasModelTests

    @available(macOS 14, *)
    func model(_ fake: FakeIntegration, saved: [SavedCamera]) -> CamerasModel {
        let store = SavedCamerasStore(document: Defaults([:]).at("document"))
        store.save(saved)
        return CamerasModel(integrations: [AppIntegration(fake)], store: store)
    }

    @available(macOS 14, *)
    @Test func pairedCardsShowRoutesProgressAndFailures() async throws {
        let fake = FakeIntegration(id: IntegrationID("test.cameras"))
        var older = T.camera
        older.id = "camera-0"
        older.name = "B cam"
        older.lastConnected = Date(timeIntervalSince1970: 500)
        let model = model(fake, saved: [older, T.camera])
        fake.publish([NearbyCamera(id: "camera-1", name: "CAM-1", model: "Test Body", routes: [.cameraAccessPoint])])
        #expect(await eventually { !model.nearby.isEmpty })
        model.connect(T.camera)
        fake.attempts[0].progress(.joiningNetwork, step: 2, note: "Joining CAM-1")
        model.connect(older, route: T.wifi.id)
        fake.attempts[1].fail(T.failure)
        #expect(await eventually { model.attempts["camera-1"]?.progress != nil && model.failures["camera-0"] != nil })

        let items = CamerasMapping.paired(model)
        #expect(
            items[0]
                == CameraListItem(
                    id: "camera-1", name: "CAM-1", subtitle: "Test Body · CAM-1", badge: "CONNECTING",
                    status: "Joining CAM-1", actionTitle: "Connect", isPrimary: true, isBusy: true,
                    isAvailable: true,
                    setups: [
                        CameraSetupChip(id: T.ap.id.description, title: "Camera Wi-Fi", isActive: true),
                        CameraSetupChip(id: T.wifi.id.description, title: "Wi-Fi · studio", isActive: false, canForget: true),
                    ],
                    canAddSetup: true,
                    steps: [
                        CameraConnectStep("Link", detail: "", state: .done),
                        CameraConnectStep("Approve", detail: "", state: .done),
                        CameraConnectStep("Join network", detail: "Joining CAM-1", state: .active),
                        CameraConnectStep("Video", detail: "", state: .waiting),
                    ]))
        #expect(
            items[1]
                == CameraListItem(
                    id: "camera-0", name: "B cam", subtitle: "Test Body · studio", badge: "NOT CONNECTED",
                    status: "Not found. Power it on to reconnect", actionTitle: "Reconnect", isAvailable: false,
                    setups: [
                        CameraSetupChip(id: T.ap.id.description, title: "Camera Wi-Fi", isActive: false),
                        CameraSetupChip(id: T.wifi.id.description, title: "Wi-Fi · studio", isActive: true, canForget: true),
                    ],
                    canAddSetup: true,
                    failure: CameraConnectFailure(
                        title: "Bluetooth is off", message: "Turn on Bluetooth for this app.",
                        actions: [
                            .init(id: "settings", title: "Open Settings"),
                            .init(id: "edit:\(T.wifi.id)", title: "Edit setup"),
                            .init(id: "retry", title: "Try again", primary: true),
                        ])))
        #expect(CamerasMapping.action("edit:\(T.wifi.id)", of: "camera-0", in: model) == .editRoute(T.wifi.id))
    }

    @available(macOS 14, *)
    @Test func nearbyCamerasAreUnsavedSightings() async {
        let fake = FakeIntegration(id: IntegrationID("test.cameras"))
        let model = model(fake, saved: [T.camera])
        fake.publish([
            NearbyCamera(id: "x", savedID: "camera-1", name: "CAM-1", model: "Test Body", routes: [.cameraAccessPoint]),
            NearbyCamera(id: "n2", name: "CAM-2", model: "Test Body", routes: [.cameraAccessPoint], signalBars: 3),
            NearbyCamera(
                id: "n3", name: "CAM-3", model: "Test Body", routes: [.cameraAccessPoint], availability: .unavailable(.busy)),
        ])
        #expect(await eventually { model.nearby.count == 3 })
        #expect(
            CamerasMapping.nearby(model) == [
                CameraListItem(
                    id: "n2", name: "CAM-2", subtitle: "Test Body · nearby", badge: "NEW", status: "Ready to pair",
                    actionTitle: "Pair", signalBars: 3),
                CameraListItem(
                    id: "n3", name: "CAM-3", subtitle: "Test Body · nearby", badge: "IN USE",
                    status: "In use by another device", actionTitle: "Pair", isAvailable: false),
            ])
    }

    @available(macOS 14, *)
    @Test func thePairPageFollowsChoosingAttemptAndFailure() async throws {
        let fake = FakeIntegration(id: IntegrationID("test.cameras"))
        let model = model(fake, saved: [])
        model.beginPairing()
        #expect(await eventually { model.scanning })
        let empty = CamerasMapping.pairing(model)
        #expect(
            empty
                == CameraPairingPresentation(
                    steps: [.init("Find your camera", "Nearby cameras")], currentStep: 0, title: "Find your camera",
                    body: "Turn the camera on and keep this phone nearby.", target: "Nothing selected yet",
                    hint: "Choose the camera that matches your screen", emptyTitle: "Looking for cameras",
                    primaryAction: "Continue"))

        fake.publish([T.sighting])
        #expect(await eventually { !model.nearby.isEmpty })
        model.selection = "n2"
        let chosen = CamerasMapping.pairing(model)
        #expect(chosen.target == "CAM-2" && chosen.hint == "Selected CAM-2" && chosen.primaryActionEnabled)
        #expect(chosen.devices.map(\.id) == ["n2"] && chosen.devices[0].isPrimary && chosen.emptyTitle == nil)

        model.connect(try #require(model.nearby.first))
        fake.attempts[0].progress(.link, step: 0)
        #expect(await eventually { model.attempts["n2"]?.progress != nil })
        let linking = CamerasMapping.pairing(model)
        #expect(linking.steps.map(\.title) == ["Find your camera", "Link", "Approve", "Join network", "Video"])
        #expect(linking.currentStep == 1 && linking.devices.isEmpty && linking.progress == "Link")
        #expect(linking.primaryAction == nil && linking.backAction == "Cancel")

        fake.attempts[0].fail(T.failure)
        #expect(await eventually { model.failures["n2"] != nil })
        let failed = CamerasMapping.pairing(model)
        #expect(failed.title == "Bluetooth is off" && failed.body == "Turn on Bluetooth for this app." && failed.error == nil)
        #expect(failed.primaryAction == "Open Settings" && failed.primaryActionEnabled && failed.currentStep == 0)
    }

    @available(macOS 14, *)
    @Test func routeTitlesFollowTheKind() {
        #expect(
            RouteKind.allCases.map { CamerasMapping.title(of: SavedRoute(key: "k", kind: $0)) }
                == ["Camera Wi-Fi", "Wi-Fi", "Hotspot", "USB-C", "HDMI"])
        #expect(CamerasMapping.title(of: SavedRoute(key: "k", kind: .usb, title: "Desk")) == "Desk")
    }
}
