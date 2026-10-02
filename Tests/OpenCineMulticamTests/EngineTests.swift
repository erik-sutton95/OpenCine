import Foundation
import OpenCineCore
import OpenCineCoreTestSupport
import OpenCineMulticam
import Testing

@Suite struct GroupTests {
    @Test func slotsSurviveReorderStagingAndSessionReplacement() async throws {
        let dji = await reported(.djiLike())
        let nikon = await reported(.nikonLike())
        let a = entry("A", dji)
        let b = entry("B", nikon)
        let hdmi = FakeEntries.captureOnly(FakePictureSource(label: "HDMI").descriptor)
        var g = try group([a, b, hdmi])
        try g.setStage(b.id)
        try g.move(b.id, to: 0)
        #expect(g.entries.map(\.id) == [b.id, a.id, hdmi.id])
        #expect(g.stage == b.id)
        try g.replaceSession(of: b.id, with: await reported(.nikonLike()))
        #expect(g.stage == b.id)
        #expect(throws: MulticamGroupError.duplicateEntry(a.id)) { try g.add(a) }
        #expect(throws: MulticamGroupError.invalidEntry(.noRole)) {
            try g.add(MonitorEntryDescriptor(name: "empty", controlAuthority: .readOnly))
        }

        let route = ConnectionRouteID()
        let layout = MulticamLayout(g, routes: [a.id: route])
        let decoded = try JSONDecoder().decode(MulticamLayout.self, from: JSONEncoder().encode(layout))
        #expect(decoded == layout)
        #expect(decoded.slots.map(\.entry) == [b.id, a.id, hdmi.id])
        #expect(decoded.slots[1].route == route)
        #expect(decoded.stage == b.id)

        g.remove(b.id)
        #expect(g.stage == nil)
        #expect(await nikon.wire.isEmpty)
    }

    @Test func pictureFailureAndStaleTelemetryNeverFakeAStoppedRecording() async throws {
        let dji = await reported(.djiLike())
        let a = entry("A", dji)
        let g = try group([a])
        _ = await dji.submit(
            CameraCommand(.startRecording, preconditions: CommandPreconditions(await dji.current)))
        await dji.advance(by: .seconds(1))

        let failed = g.summary(
            at: await state([dji], pictures: [a.picture!.stream: .failed]), telemetryMaxAge: .seconds(3))
        #expect(failed.entries[0].picture == .reported(.failed))
        #expect(failed.entries[0].control == .reported(.ready))
        #expect(failed.entries[0].recording.value == .recording)
        #expect(failed.camerasRecording == 1)
        #expect(failed.livePictures == 0)

        await dji.advance(by: .seconds(5))
        let stale = g.summary(at: await state([dji]), telemetryMaxAge: .seconds(3))
        #expect(stale.entries[0].telemetry == .stale)
        #expect(stale.staleTelemetry == 1)
        #expect(stale.entries[0].recording.value == .recording)
    }
}

@Suite struct EditorLeaseTests {
    @Test func leaseRetiresWhenEpochOrSessionChanges() async throws {
        let nikon = await reported(.nikonLike())
        let a = entry("A", nikon)
        var g = try group([a])
        var leases = EditorLeases()
        var live = await state([nikon])
        let lease = try leases.open(a.id, in: g, at: live)
        #expect(leases.refusal(for: lease, in: g, at: live) == nil)
        let iso = SettingValue.iso(.manual(800))
        let edit = try leases.command(.set(iso), under: lease, in: g, at: live)
        #expect(await nikon.submit(edit).stage == .awaitingObservation)

        // Built before the link was replaced, flushed after.
        let queued = try leases.command(.set(.iso(.manual(1600))), under: lease, in: g, at: live)
        await nikon.completeAttempt(await nikon.loseLink())
        live = await state([nikon])
        #expect(leases.refusal(for: lease, in: g, at: live) == .retired)
        #expect(throws: EditorLeaseRefusal.retired) {
            try leases.command(.set(iso), under: lease, in: g, at: live)
        }
        let retired = leases.retireStale(in: g, at: live)
        #expect(retired == [lease])
        #expect(await nikon.submit(queued).stage == .rejected(.staleEpoch))

        let second = try leases.open(a.id, in: g, at: live)
        let queuedForOld = try leases.command(.set(iso), under: second, in: g, at: live)
        let replacement = await reported(.nikonLike())
        try g.replaceSession(of: a.id, with: replacement)
        let now = await state([nikon, replacement])
        #expect(throws: EditorLeaseRefusal.retired) {
            try leases.command(.set(iso), under: second, in: g, at: now)
        }
        #expect(await replacement.submit(queuedForOld).stage == .rejected(.wrongSession))
        #expect(await replacement.wire.isEmpty)
    }

    @Test func closingReopeningOrLosingAuthorityRetires() async throws {
        let dji = await reported(.djiLike())
        let a = entry("A", dji)
        let relay = entry("relay", dji, authority: .readOnly)
        let g = try group([a, relay])
        let live = await state([dji])
        var leases = EditorLeases()
        #expect(throws: EditorLeaseRefusal.noCommandAuthority) {
            try leases.open(relay.id, in: g, at: live)
        }
        let first = try leases.open(a.id, in: g, at: live)
        let second = try leases.open(a.id, in: g, at: live)
        #expect(throws: EditorLeaseRefusal.retired) {
            try leases.command(.set(.zoom(2)), under: first, in: g, at: live)
        }
        leases.close(a.id)
        #expect(throws: EditorLeaseRefusal.retired) {
            try leases.command(.set(.zoom(2)), under: second, in: g, at: live)
        }
        let third = try leases.open(a.id, in: g, at: live)
        await dji.setAuthority(.readOnly)
        let afterLapse = await state([dji])
        let retired = leases.retireStale(in: g, at: afterLapse)
        #expect(retired == [third])
        #expect(leases.leases.isEmpty)
        #expect(await dji.wire.isEmpty)
    }
}

@Suite struct ResourceAdmissionTests {
    let budget = ResourceBudget(qualifiedEntries: 4)
    let integration = IntegrationID("test.cameras")

    func device(_ serial: String) -> CameraDeviceID { .durable(serial, integration: integration) }

    func request(_ device: CameraDeviceID?, _ claims: [ResourceClaim], bits: Int = 0) -> ResourceRequest {
        ResourceRequest(entry: MonitorEntryID(), device: device, claims: claims, bitsPerSecond: bits)
    }

    func reasons(_ candidate: ResourceRequest, _ members: [ResourceRequest]) -> [AdmissionReason] {
        ResourceAdmission.reasons(admitting: candidate, alongside: members, budget: budget)
    }

    @Test func qualificationIsRequiredAndResourceLimitsStillApply() {
        let members = (0..<4).map { request(device("\($0)"), []) }
        let candidate = request(device("candidate"), [])
        func qualifiedReasons(_ verdict: MulticamQualification, _ alongside: [ResourceRequest])
            -> [AdmissionReason]
        {
            ResourceAdmission.reasons(
                admitting: candidate, qualification: verdict, alongside: alongside, budget: budget)
        }
        #expect(qualifiedReasons(.qualified, []).isEmpty)
        #expect(qualifiedReasons(.unknown, []) == [.qualificationUnknown])
        #expect(
            qualifiedReasons(.refused(.unsupportedConfiguration), [])
                == [.integrationRefused(.unsupportedConfiguration)])
        #expect(qualifiedReasons(.qualified, members) == [.overQualifiedLimit(4)])
        #expect(
            qualifiedReasons(.unknown, members) == [.qualificationUnknown, .overQualifiedLimit(4)])
        // Replacing this entry does not consume a second slot.
        #expect(qualifiedReasons(.qualified, Array(members.prefix(3)) + [candidate]).isEmpty)
        // Unlimited resource capacity still cannot qualify an unknown configuration.
        #expect(
            ResourceAdmission.reasons(
                admitting: candidate, qualification: .unknown, alongside: members,
                budget: ResourceBudget(qualifiedEntries: nil)) == [.qualificationUnknown])
    }

    @Test func conflictingClaimsAreRejectedWithReasons() {
        let apOne = request(device("1"), [.cameraAccessPoint(network: "CAM-1")])
        let apTwo = request(device("2"), [.cameraAccessPoint(network: "CAM-2")])
        #expect(reasons(apTwo, [apOne]) == [.wifiNetworkConflict(with: apOne.entry)])
        let sharing = request(device("2"), [.cameraAccessPoint(network: "CAM-1")])
        #expect(reasons(sharing, [apOne]) == [.accessPointTaken(by: apOne.entry)])
        // The same camera's control entry rides along on its access point.
        #expect(reasons(request(device("1"), [.cameraAccessPoint(network: "CAM-1")]), [apOne]).isEmpty)
        let lan = request(device("2"), [.infrastructureNetwork("studio")])
        #expect(reasons(lan, [apOne]) == [.wifiNetworkConflict(with: apOne.entry)])

        let usb = request(device("1"), [.usbInterface("usb-0")])
        #expect(reasons(request(device("2"), [.usbInterface("usb-0")]), [usb]) == [.usbInterfaceTaken(by: usb.entry)])
        // USB control plus a capture-device picture use distinct resources.
        #expect(reasons(request(nil, [.usbInterface("capture-0")], bits: 50), [usb]).isEmpty)

        let pairing = request(device("2"), [.bluetoothCommissioning])
        #expect(
            reasons(request(device("3"), [.bluetoothCommissioning]), [pairing])
                == [.commissioningInProgress(by: pairing.entry)])
    }

    @Test func sharedNetworkCoexistsUpToTheInjectedLimit() {
        let members = (1...4).map { request(device("\($0)"), [.infrastructureNetwork("studio")], bits: 10) }
        for index in members.indices {
            #expect(reasons(members[index], Array(members[..<index])).isEmpty)
        }
        let fifth = request(device("5"), [.infrastructureNetwork("studio")], bits: 10)
        #expect(reasons(fifth, members) == [.overQualifiedLimit(4)])
        #expect(
            ResourceAdmission.reasons(
                admitting: fifth, alongside: members,
                budget: ResourceBudget(qualifiedEntries: 6, bitsPerSecond: 45))
                == [.bandwidthExceeded(needed: 50, limit: 45)])
    }

    @Test func savedRoutesClaimByTheTable() {
        func claims(_ kind: RouteKind, _ network: String?, bluetooth: Bool = false) -> [ResourceClaim] {
            ResourceClaim.claims(for: SavedRoute(key: "k", kind: kind, network: network, bluetooth: bluetooth))
        }
        #expect(claims(.cameraAccessPoint, "CAM-1") == [.cameraAccessPoint(network: "CAM-1")])
        #expect(claims(.infrastructureNetwork, "studio") == [.infrastructureNetwork("studio")])
        #expect(claims(.phoneHotspot, "phone") == [.infrastructureNetwork("hotspot:phone")])
        #expect(claims(.usb, "usb-0") == [.usbInterface("usb-0")])
        #expect(claims(.captureDevice, "capture-0") == [.usbInterface("capture-0")])
        #expect(
            claims(.cameraAccessPoint, "CAM-1", bluetooth: true)
                == [.cameraAccessPoint(network: "CAM-1"), .bluetoothCommissioning])
        // Unknown networks never match each other.
        #expect(claims(.infrastructureNetwork, nil) != claims(.infrastructureNetwork, nil))

        // A hotspot conflicts with the router network a member uses.
        let router = ResourceRequest(
            entry: MonitorEntryID(), device: device("1"),
            route: SavedRoute(key: "wifi", kind: .infrastructureNetwork, network: "studio"), picture: true)
        let hotspot = ResourceRequest(
            entry: MonitorEntryID(), device: device("2"),
            route: SavedRoute(key: "hotspot", kind: .phoneHotspot, network: "studio"), picture: true,
            bitsPerSecond: 10)
        #expect(router.decoders == 1 && hotspot.bitsPerSecond == 10)
        #expect(reasons(hotspot, [router]) == [.wifiNetworkConflict(with: router.entry)])
    }
}

@Suite struct RecoveryTests {
    @Test func failingEntryExhaustsOnlyItsOwnBudget() async throws {
        let healthyCamera = await reported(.djiLike())
        let failing = MonitorEntryID()
        let healthy = MonitorEntryID()
        var ledger = RecoveryLedger(limit: 2, resetAfterHealthy: .seconds(30))
        let attempts = (1...3).map { _ in ledger[failing].beginAttempt() }
        #expect(attempts == [true, true, false])
        #expect(ledger[failing].status == .exhausted)
        #expect(ledger.exhausted == [failing])
        #expect(ledger[healthy].status == .healthy)
        let peerAttempt = ledger[healthy].beginAttempt()
        #expect(peerAttempt)
        // The engine never touches a peer's session.
        #expect(await healthyCamera.current.connection == .ready)
        #expect(await healthyCamera.wire.isEmpty)
        ledger[failing].reset()
        #expect(ledger[failing].status == .healthy)

        var g = MulticamGroup()
        try g.add(entry("H", healthyCamera))
        ledger.prune(to: g)
        #expect(ledger.budgets.isEmpty)
    }

    @Test func sustainedHealthRestoresTheBudget() {
        var budget = RecoveryBudget(limit: 2, resetAfterHealthy: .seconds(30))
        _ = budget.beginAttempt()
        _ = budget.beginAttempt()
        #expect(budget.status == .recovering(attempt: 2, of: 2))
        budget.observe(healthy: true, at: MonotonicInstant(.seconds(10)))
        budget.observe(healthy: false, at: MonotonicInstant(.seconds(20)))
        budget.observe(healthy: true, at: MonotonicInstant(.seconds(21)))
        budget.observe(healthy: true, at: MonotonicInstant(.seconds(50)))
        #expect(budget.used == 2)
        budget.observe(healthy: true, at: MonotonicInstant(.seconds(51)))
        #expect(budget.used == 0)
        #expect(budget.status == .healthy)
    }
}

@Suite struct ImportRuleTests {
    @Test func engineImportsOnlyFoundationAndCoreAndNamesNoVendorOrUI() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(
            at: root.appending(path: "Sources/OpenCineMulticam"), includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        let forbidden = try Regex(
            #"\b(swiftui|uikit|appkit|compose|androidx|dji|osmo|nikon|zcine|insta360|insta|luna|pocket|sony|canon|blackmagic|gopro|datalink|ptp|udp)\b"#
        ).ignoresCase()
        #expect("import SwiftUI".firstMatch(of: forbidden) != nil)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") where line.hasPrefix("import ") {
                #expect(["import Foundation", "import OpenCineCore"].contains(line), "\(file.lastPathComponent): \(line)")
            }
            #expect(text.firstMatch(of: forbidden) == nil, "\(file.lastPathComponent)")
        }
        // One dependency, OpenCineCore: the target's edge in the platform manifest.
        let manifest = try String(contentsOf: root.appending(path: "Package.swift"), encoding: .utf8)
        #expect(manifest.contains(#".target(name: "OpenCineMulticam", dependencies: ["OpenCineCore"])"#))
    }
}
