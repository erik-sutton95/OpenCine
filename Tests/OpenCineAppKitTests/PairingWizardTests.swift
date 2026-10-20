import Foundation
import MonitorPresentation
import OpenCineAppKit
import OpenCineCore
import OpenCineCoreTestSupport
import Testing

/// The four-page pair wizard as Pocket and Insta main showed it (their `OsmoCameraPageAdapter`
/// pairing tests). Kotlin mirror: `PairingWizardTest`, same method names and values.
@MainActor
@Suite struct PairingWizardTests {
    typealias T = CamerasModelTests

    static let wizard = PairingWizard(
        bodies: ["Find body", "Approve body", "Wi-Fi body", "Video body"],
        approveLines: ["Tap Allow"], joinLines: ["Leave it on"],
        choosing: CameraPairingInstruction(title: "Check first", icon: .phone, lines: ["Quit the other app."]),
        label: "Live label")

    @available(macOS 14, *)
    func model(saved: [SavedCamera] = [], copy: ((NearbyCamera) -> NearbyCardCopy)? = nil) -> (CamerasModel, FakeIntegration) {
        let fake = FakeIntegration(id: IntegrationID("test.cameras"))
        let store = SavedCamerasStore(document: Defaults([:]).at("document"))
        store.save(saved)
        return (CamerasModel(integrations: [AppIntegration(fake, slots: IntegrationSlots(nearbyCard: copy))], store: store), fake)
    }

    @available(macOS 14, *)
    @Test func choosingShowsTheFourPagesThePreCheckAndTheScanLabel() async {
        let (model, fake) = model()
        model.beginPairing()
        #expect(await eventually { model.scanning })
        let empty = CamerasMapping.wizard(model, Self.wizard)
        #expect(
            empty
                == CameraPairingPresentation(
                    steps: [
                        .init("Find your camera", "Bluetooth scan"), .init("Approve on the camera", "Camera prompt"),
                        .init("Join camera Wi-Fi", "Camera network"), .init("Open video link", "Video link"),
                    ],
                    currentStep: 0, title: "Find your camera", body: "Find body", target: "Nothing selected yet",
                    hint: "Choose the camera that matches your screen", progress: "Live label",
                    instructions: [.init(title: "Check first", icon: .phone, lines: ["Quit the other app."])],
                    emptyTitle: "Looking for cameras", primaryAction: "Continue"))
        var blocked = Self.wizard
        blocked.discoveryFailure = T.failure
        #expect(CamerasMapping.wizard(model, blocked).emptyTitle == "No cameras yet")

        fake.publish([T.sighting])
        #expect(await eventually { !model.nearby.isEmpty })
        #expect(CamerasMapping.wizard(model, Self.wizard).primaryActionEnabled == false)
        model.selection = "n2"
        let chosen = CamerasMapping.wizard(model, Self.wizard)
        #expect(chosen.target == "CAM-2" && chosen.hint == "Selected CAM-2" && chosen.primaryActionEnabled)
        #expect(chosen.devices.map(\.id) == ["n2"] && chosen.devices[0].isPrimary && chosen.emptyTitle == nil)
        #expect(chosen.backAction == nil)
    }

    @available(macOS 14, *)
    @Test func aConnectAdvancesTheRailFromTheReportedSteps() async throws {
        let (model, fake) = model(saved: [T.camera])
        model.beginPairing()
        fake.publish([T.sighting])
        #expect(await eventually { !model.nearby.isEmpty })
        model.selection = "n2"
        model.connect(try #require(model.nearby.first))
        #expect(await eventually { model.attempts["n2"] != nil })
        let starting = CamerasMapping.wizard(model, Self.wizard)
        #expect(starting.currentStep == 1 && starting.devices.isEmpty && starting.progress == "Live label")
        #expect(starting.primaryAction == nil && !starting.primaryActionEnabled && starting.backAction == "Cancel")

        fake.attempts[0].progress(.link, step: 0, note: "Looking for the camera")
        #expect(await eventually { model.attempts["n2"]?.progress != nil })
        #expect(CamerasMapping.wizard(model, Self.wizard).currentStep == 0)

        fake.attempts[0].progress(.awaitingApproval, step: 0, prompt: .approveOnCamera("Approve"))
        #expect(await eventually { model.attempts["n2"]?.progress?.phase == .awaitingApproval })
        let approve = CamerasMapping.wizard(model, Self.wizard)
        #expect(approve.currentStep == 1 && approve.title == "Approve on the camera" && approve.body == "Approve body")
        #expect(approve.hint == "Nothing to type. Approve it on the camera" && approve.checks.isEmpty)
        #expect(
            approve.instructions == [
                .init(title: "On the camera", icon: .camera, lines: ["Tap Allow"]),
                .init(
                    title: "On iPhone", icon: .phone,
                    lines: ["Wait here, we keep the Bluetooth link alive", "Don't force-quit the app"]),
            ])

        fake.attempts[0].progress(.joiningNetwork, step: 1)
        #expect(await eventually { model.attempts["n2"]?.progress?.current == 1 })
        var wizard = Self.wizard
        wizard.joinedNetwork = "LUNA-1"
        let join = CamerasMapping.wizard(model, wizard)
        #expect(join.currentStep == 2 && join.hint == "iOS asks to join the camera network")
        #expect(
            join.instructions == [
                .init(title: "On the camera", icon: .camera, lines: ["Leave it on"]),
                .init(
                    title: "On iPhone", icon: .phone,
                    lines: ["Tap Join when iOS asks to join the camera network", LocalVPNFilter.joinWifiPhoneStep]),
            ])
        #expect(
            join.checks == [
                .init(title: "Bluetooth link", subtitle: "CAM-2", state: .complete, stateLabel: "OK"),
                .init(title: "Camera Wi-Fi", subtitle: "LUNA-1", state: .active, stateLabel: "JOINING"),
                .init(title: "Live picture", subtitle: "Starts after Wi-Fi joins", state: .waiting, stateLabel: "WAITING"),
            ])

        fake.attempts[0].progress(.link, step: 2)
        #expect(await eventually { model.attempts["n2"]?.progress?.current == 2 })
        let video = CamerasMapping.wizard(model, Self.wizard)
        #expect(video.currentStep == 3 && video.instructions.isEmpty && video.checks.last?.stateLabel == "WAITING")
        #expect(video.checks.last?.subtitle == "Opening the video link…")
        wizard.vpnActive = true
        #expect(
            CamerasMapping.wizard(model, wizard).instructions == [
                .init(title: "Check the connection", icon: .phone, lines: [LocalVPNFilter.wizardBanner])
            ])
    }

    @available(macOS 14, *)
    @Test func aFailureReturnsToTheFirstPageWithItsErrorAndAction() async throws {
        let (model, fake) = model()
        model.beginPairing()
        fake.publish([T.sighting])
        #expect(await eventually { !model.nearby.isEmpty })
        model.selection = "n2"
        model.connect(try #require(model.nearby.first))
        #expect(await eventually { model.attempts["n2"] != nil })
        var failure = T.failure
        failure.actions = [.retry]
        fake.attempts[0].fail(failure)
        #expect(await eventually { model.failures["n2"] != nil })
        let failed = CamerasMapping.wizard(model, Self.wizard)
        #expect(failed.currentStep == 0 && failed.title == "Find your camera" && failed.body == "Find body")
        #expect(failed.error == "Turn on Bluetooth for this app." && failed.progress == nil && failed.instructions.isEmpty)
        #expect(failed.primaryAction == "Try again" && failed.primaryActionEnabled)

        model.dismissFailure("n2")
        #expect(CamerasMapping.wizard(model, Self.wizard).error == nil)

        var wizard = Self.wizard
        wizard.discoveryFailure = T.failure
        let settings = CamerasMapping.wizard(model, wizard)
        #expect(settings.error == "Turn on Bluetooth for this app." && settings.primaryAction == "Open Settings")
    }

    @available(macOS 14, *)
    @Test func aFailedPairKeepsItsReasonAfterTheRescanClearsSightings() async throws {
        let (model, fake) = model()
        model.beginPairing()
        fake.publish([T.sighting])
        #expect(await eventually { !model.nearby.isEmpty })
        model.selection = "n2"
        model.connect(try #require(model.nearby.first))
        #expect(await eventually { model.attempts["n2"] != nil })
        var failure = T.failure
        failure.actions = [.retry]
        fake.attempts[0].fail(failure)
        #expect(await eventually { model.failures["n2"] != nil })
        fake.publish([])
        #expect(await eventually { model.nearby.isEmpty })
        let failed = CamerasMapping.wizard(model, Self.wizard)
        #expect(failed.error == failure.message)
        #expect(failed.primaryAction == "Try again")
        #expect(failed.target == "CAM-2")
    }

    @available(macOS 14, *)
    @Test func theAppWordsNearbyCards() async {
        let (model, fake) = model(copy: { NearbyCardCopy(name: $0.name, subtitle: "Brand · nearby", status: "Needs approval on the camera") })
        fake.publish([
            T.sighting,
            NearbyCamera(id: "n3", name: "CAM-3", model: "Test Body", routes: [.cameraAccessPoint], availability: .unavailable(.busy)),
        ])
        #expect(await eventually { model.nearby.count == 2 })
        #expect(
            CamerasMapping.nearby(model) == [
                CameraListItem(
                    id: "n2", name: "CAM-2", subtitle: "Brand · nearby", badge: "NEW",
                    status: "Needs approval on the camera", actionTitle: "Pair"),
                CameraListItem(
                    id: "n3", name: "CAM-3", subtitle: "Brand · nearby", badge: "IN USE",
                    status: "In use by another device", actionTitle: "Pair", isAvailable: false),
            ])
    }
}
