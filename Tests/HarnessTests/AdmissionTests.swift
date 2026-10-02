import HarnessComposition
import OpenCineCore
import OpenCineMulticam
import Testing

/// SIMULATED. Plan 8.4 and MULTI-03 step 5: route claims from the composition root through
/// OpenCineMulticam's `ResourceAdmission`. Feasibility only; nothing is provisioned, and no
/// combination here is hardware-qualified (docs/TOPOLOGY.md).
@MainActor
@Suite struct AdmissionTests {
    private let budget = ResourceBudget(qualifiedEntries: 4)

    private func route(_ factory: IntegrationFactory, _ kind: RouteKind) throws -> RouteOffer {
        try #require(factory.routes.first { $0.kind == kind })
    }

    private func device(_ factory: IntegrationFactory, _ serial: String) -> CameraDeviceID {
        .durable(serial, integration: factory.id)
    }

    @Test func lunaAccessPointConflictsWithAnInfrastructureNetwork() throws {
        let pocket = MonitorEntryID()
        let z = MonitorEntryID()
        let luna = MonitorEntryID()
        let members = [
            try route(Composition.dji, .infrastructureNetwork).request(
                entry: pocket, device: device(Composition.dji, "P1"), resource: "set-router"),
            try route(Composition.nikon, .infrastructureNetwork).request(
                entry: z, device: device(Composition.nikon, "Z1"), resource: "set-router"),
        ]
        #expect(ResourceAdmission.reasons(admitting: members[1], alongside: [members[0]], budget: budget).isEmpty)

        // Luna's only route is its own access point: the phone would have to leave the router.
        let candidate = try route(Composition.luna, .cameraAccessPoint).request(
            entry: luna, device: device(Composition.luna, "L1"), resource: "Luna-L1")
        #expect(
            ResourceAdmission.reasons(admitting: candidate, alongside: members, budget: budget)
                == [.wifiNetworkConflict(with: pocket), .wifiNetworkConflict(with: z)])
        #expect(!Composition.luna.routes.contains { $0.kind == .infrastructureNetwork })
    }

    @Test func twoCameraAccessPointsCannotShareOnePhone() throws {
        let luna = try route(Composition.luna, .cameraAccessPoint).request(
            entry: MonitorEntryID(), device: device(Composition.luna, "L1"), resource: "Luna-L1")
        let pocketAP = try route(Composition.dji, .cameraAccessPoint).request(
            entry: MonitorEntryID(), device: device(Composition.dji, "P1"), resource: "OsmoPocket-P1")
        #expect(
            ResourceAdmission.reasons(admitting: pocketAP, alongside: [luna], budget: budget)
                == [.wifiNetworkConflict(with: luna.entry)])
        let secondLuna = try route(Composition.luna, .cameraAccessPoint).request(
            entry: MonitorEntryID(), device: device(Composition.luna, "L2"), resource: "Luna-L2")
        #expect(
            ResourceAdmission.reasons(admitting: secondLuna, alongside: [luna], budget: budget)
                == [.wifiNetworkConflict(with: luna.entry)])
    }

    @Test func nikonUSBControlAndHDMIPictureCoexist() throws {
        let z = device(Composition.nikon, "Z1")
        let control = try route(Composition.nikon, .usb).request(
            entry: MonitorEntryID(), device: z, resource: "usb:ptp")
        // The HDMI picture is of the same body, on a separate capture interface.
        let picture = try route(Composition.hdmiCapture, .captureDevice).request(
            entry: MonitorEntryID(), device: z, resource: "usb:uvc")
        #expect(ResourceAdmission.reasons(admitting: picture, alongside: [control], budget: budget).isEmpty)

        // A second body cannot take the same USB interface.
        let other = try route(Composition.nikon, .usb).request(
            entry: MonitorEntryID(), device: device(Composition.nikon, "Z2"), resource: "usb:ptp")
        #expect(
            ResourceAdmission.reasons(admitting: other, alongside: [control, picture], budget: budget)
                == [.usbInterfaceTaken(by: control.entry)])
    }

    @Test func theAppQualificationLimitIsABudgetValue() throws {
        let members = try (1...4).map { index in
            try route(Composition.nikon, .infrastructureNetwork).request(
                entry: MonitorEntryID(), device: device(Composition.nikon, "Z\(index)"), resource: "set-router")
        }
        let fifth = try route(Composition.dji, .infrastructureNetwork).request(
            entry: MonitorEntryID(), device: device(Composition.dji, "P5"), resource: "set-router")
        #expect(
            ResourceAdmission.reasons(admitting: fifth, alongside: members, budget: budget)
                == [.overQualifiedLimit(4)])
        #expect(
            ResourceAdmission.reasons(
                admitting: fifth, alongside: members, budget: ResourceBudget(qualifiedEntries: nil)
            ).isEmpty)
    }
}
