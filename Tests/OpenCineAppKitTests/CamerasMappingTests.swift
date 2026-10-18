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
    @Test func editSetupReopensOnlyAnAdvertisedCurrentRoute() async {
        let fake = FakeIntegration(id: IntegrationID("test.cameras"))
        let model = model(fake, saved: [T.camera])
        let chooser = AddSetupChooser(
            title: "Add setup", detail: "",
            options: [
                AddSetupOption(
                    id: "wifi", kind: .infrastructureNetwork, title: "Wi-Fi", detail: "",
                    actionTitle: "Choose"),
                AddSetupOption(
                    id: "hotspot", kind: .phoneHotspot, title: "Hotspot", detail: "",
                    actionTitle: "Choose"),
            ])
        model.connect(T.camera, route: T.wifi.id)
        fake.attempts[0].fail(T.failure)
        #expect(await eventually { model.failures[T.camera.id] != nil })
        #expect(
            CamerasMapping.addSetupSelection(model, camera: T.camera, chooser: chooser) == "wifi")
        var removed = T.camera
        removed.routes.removeAll { $0.kind == .infrastructureNetwork }
        #expect(CamerasMapping.addSetupSelection(model, camera: removed, chooser: chooser) == nil)
        var unsupported = chooser
        unsupported.options.removeAll { $0.kind == .infrastructureNetwork }
        #expect(
            CamerasMapping.addSetupSelection(model, camera: T.camera, chooser: unsupported) == nil)
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
                        CameraSetupChip(id: T.ap.id.description, title: "Camera Wi-Fi", isActive: true, kind: "cameraWiFi"),
                        CameraSetupChip(id: T.wifi.id.description, title: "Wi-Fi · studio", isActive: false, canForget: true, kind: "wifi"),
                    ],
                    canAddSetup: false,
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
                        CameraSetupChip(id: T.ap.id.description, title: "Camera Wi-Fi", isActive: false, kind: "cameraWiFi"),
                        CameraSetupChip(id: T.wifi.id.description, title: "Wi-Fi · studio", isActive: true, canForget: true, kind: "wifi"),
                    ],
                    canAddSetup: false,
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
    @Test func aCameraWithoutModelOrSpareRoute() async {
        let fake = FakeIntegration(id: IntegrationID("test.cameras"))
        var camera = T.camera
        camera.model = ""
        camera.routes = [T.wifi]
        camera.preferredRoute = T.wifi.id
        let model = model(fake, saved: [camera])
        let item = CamerasMapping.paired(model)[0]
        #expect(item.subtitle == "studio" && item.setups.map(\.canForget) == [false])
        fake.publish([NearbyCamera(id: "n9", name: "CAM-9", model: "", routes: [.infrastructureNetwork])])
        #expect(await eventually { !model.nearby.isEmpty })
        #expect(CamerasMapping.nearby(model).map(\.subtitle) == ["nearby"])
    }

    @available(macOS 14, *)
    @Test func addIsOfferedOnlyWhileAnAddableKindIsMissing() {
        let fake = FakeIntegration(id: IntegrationID("test.cameras"))
        var camera = T.camera
        camera.routes = [T.ap]
        camera.preferredRoute = T.ap.id
        #expect(CamerasMapping.paired(model(fake, saved: [camera]))[0].canAddSetup)
        camera.routes = [T.ap, T.wifi]
        #expect(!CamerasMapping.paired(model(fake, saved: [camera]))[0].canAddSetup)
    }

    @available(macOS 14, *)
    @Test func nearbyCamerasAreUnsavedSightings() async {
        let fake = FakeIntegration(id: IntegrationID("test.cameras"))
        let model = model(fake, saved: [T.camera])
        fake.publish([
            NearbyCamera(
                id: "x", savedID: "camera-1", name: "CAM-1", model: "Test Body",
                routes: [.cameraAccessPoint]),
            NearbyCamera(
                id: "n2", name: "CAM-2", model: "Test Body", routes: [.cameraAccessPoint],
                signalBars: 3),
            NearbyCamera(
                id: "n3", name: "CAM-3", model: "Test Body", routes: [.cameraAccessPoint],
                availability: .unavailable(.busy)),
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
        #expect(
            linking.steps.map(\.title) == [
                "Find your camera", "Link", "Approve", "Join network", "Video",
            ])
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
