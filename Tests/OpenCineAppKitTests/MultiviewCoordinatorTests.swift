import Foundation
import OpenCineAppKit
import OpenCineCore
import OpenCineCoreTestSupport
import OpenCineMulticam
import Testing

/// The shared Multiview coordinator against fake seams: the behaviors OpenPocketCine's session
/// pinned, now one implementation. Kotlin twin: `MultiviewCoordinatorTest`.
@MainActor @Suite struct MultiviewCoordinatorTests {
    @available(macOS 14, *)
    @Test func restoredStagesKeepPresentationButNeverNetworkOrCameras() {
        let stage = Fixture(
            saved: .init(
                ssid: "Previous network", hotspot: true, layout: "2 × 2 grid", focusedIndex: 2,
                cameras: [journalCamera(slot: 0)], pendingReset: [], returnedToCameraWiFi: true,
                fill: true))
        let c = stage.coordinator
        c.start()
        #expect(!c.networkConfigured, "every stage asks for its network")
        #expect(c.ssid == "")
        #expect(!c.usePhoneHotspot, "an old hotspot stage does not lock the network kind")
        #expect(c.password == "")
        #expect(c.members.allSatisfy { $0.camera == nil }, "old slots never reconnect")
        #expect(c.presentation.layout == .grid)
        #expect(c.presentation.selected == 2)
        #expect(c.presentation.fill)
        c.stop()
    }

    @available(macOS 14, *)
    @Test func credentialsLoadOnlyAfterAnExplicitNetworkChoice() {
        let stage = Fixture()
        stage.passwords["Test phone hotspot|true"] = "saved-test-password"
        let c = stage.coordinator
        c.selectNetworkSource(hotspot: true)
        #expect(stage.lookups.isEmpty)
        c.selectNetwork("Test phone hotspot")
        #expect(c.password == "saved-test-password")
        #expect(stage.lookups.first?.hotspot == true)
        c.networkConfigured = true
        c.selectNetworkSource(hotspot: false)
        #expect(!c.networkConfigured, "changing the source invalidates the confirmation")
        #expect(!c.usePhoneHotspot)
        #expect(c.ssid == "")
        #expect(c.password == "")
        c.selectNetwork("Test local Wi-Fi")
        #expect(stage.lookups.count == 2)
        #expect(stage.lookups.last?.ssid == "Test local Wi-Fi")
        #expect(stage.lookups.last?.hotspot == false)
        #expect(!c.networkConfigured, "selecting a name still needs Connect")
        c.password = "old-test-password"
        c.selectNetwork("Unsaved test network")
        #expect(c.password == "", "another network never keeps an unrelated password")
    }

    @available(macOS 14, *)
    @Test func anAssignedCameraLocksTheNetworkUntilRemoved() async {
        let stage = Fixture()
        let c = stage.coordinator
        c.networkConfigured = true
        c.ssid = "Old hotspot"
        c.usePhoneHotspot = true
        c.members[0].camera = FakeStationCamera(name: "Camera A")
        c.selectNetworkSource(hotspot: false)
        #expect(c.usePhoneHotspot, "an assigned camera still owns the network")
        c.selectNetwork("Other network")
        #expect(c.ssid == "Old hotspot")
        #expect(await !c.configureNetwork())
        #expect(c.remove(slot: 0))
        c.selectNetworkSource(hotspot: false)
        c.selectNetwork("New local Wi-Fi")
        #expect(!c.usePhoneHotspot)
        #expect(c.ssid == "New local Wi-Fi")
        #expect(!c.networkConfigured)
    }

    @available(macOS 14, *)
    @Test func legacyAssignedCamerasBecomeCleanupOnly() {
        let stage = Fixture()
        let camera = journalCamera(slot: 0)
        stage.coordinator.restoreStage(
            .init(
                ssid: "Legacy hotspot", hotspot: true, layout: "2 × 2 grid", focusedIndex: 0,
                cameras: [camera], returnedToCameraWiFi: false))
        #expect(!stage.coordinator.networkConfigured)
        #expect(stage.coordinator.members.allSatisfy { $0.camera == nil })
        #expect(stage.journal?.ssid == "")
        #expect(stage.journal?.cameras == [])
        #expect(stage.journal?.pendingReset == [camera])
    }

    @available(macOS 14, *)
    @Test func cancellingSetupKeepsPresentationPreferences() async {
        let saved = MultiviewStageJournal.Stage(
            ssid: "Previous network", hotspot: true, layout: "2 × 2 grid", focusedIndex: 2,
            cameras: [], pendingReset: [], returnedToCameraWiFi: true, fill: true)
        let stage = Fixture()
        stage.journal = saved
        stage.coordinator.restoreStage(saved)
        #expect(await stage.coordinator.closeStage())
        #expect(stage.journal == saved, "a cancelled setup leaves the last preferences")
    }

    @available(macOS 14, *)
    @Test func cleanupOnlyRestoreDefersRadioWorkUntilClose() async {
        for ssid in ["", "Forgotten test network"] {
            let camera = journalCamera(slot: 0)
            let stage = Fixture()
            stage.coordinator.restoreStage(
                .init(
                    ssid: ssid, hotspot: false, layout: "Grid", focusedIndex: 0, cameras: [],
                    pendingReset: [camera]))
            #expect(stage.commissioner.restores.isEmpty, "entering setup never moves a camera")
            #expect(!stage.coordinator.networkConfigured)
            #expect(stage.journal?.pendingReset?.map(\.id) == [camera.id])
            #expect(await stage.coordinator.closeStage())
            #expect(stage.commissioner.restores == [camera.id])
            #expect(stage.journal == nil)
        }
    }

    @available(macOS 14, *)
    @Test func closeRetriesUnfinishedCleanupOnTheNextClose() async {
        let stage = Fixture()
        let camera = FakeStationCamera(name: "Scan camera")
        stage.commissioner.restoreResults[camera.id] = [.failed]
        #expect(stage.coordinator.recordStationChange(camera))
        #expect(stage.journal?.ssid == "")
        #expect(stage.journal?.cameras == [])
        #expect(stage.journal?.pendingReset?.map(\.id) == [camera.id])
        #expect(await !stage.coordinator.closeStage())
        #expect(stage.coordinator.hasPendingCleanup)
        #expect(stage.coordinator.error == MultiviewCopy.closeCleanupFailed)
        #expect(stage.journal?.pendingReset?.map(\.id) == [camera.id])
        #expect(await stage.coordinator.closeStage())
        #expect(stage.commissioner.restores == [camera.id, camera.id])
        #expect(stage.journal == nil)
        #expect(!stage.coordinator.hasPendingCleanup)
    }

    @available(macOS 14, *)
    @Test func aDeferredReturnShowsTheIntegrationsCopy() async {
        let stage = Fixture()
        let camera = FakeStationCamera(name: "Scan camera")
        let copy = "Approve this phone on the camera, then close Multiview again."
        stage.commissioner.restoreResults[camera.id] = [.deferred(copy)]
        stage.coordinator.recordStationChange(camera)
        #expect(await !stage.coordinator.closeStage())
        #expect(stage.coordinator.error == copy)
        #expect(await stage.coordinator.closeStage())
    }

    @available(macOS 14, *)
    @Test func closeReusesAnUncancelledScanCleanup() async throws {
        let stage = Fixture()
        let gate = FakeGate()
        stage.commissioner.restoreGate = gate
        let camera = FakeStationCamera(name: "Scan camera")
        stage.coordinator.recordStationChange(camera)
        let saved = try #require(stage.journal?.pendingReset?.first)
        let scanCleanup = Task { await stage.coordinator.resetStationOnce(saved) }
        await until { gate.waiting == 1 }
        scanCleanup.cancel()
        let closing = Task { await stage.coordinator.closeStage() }
        await until { stage.coordinator.closing }
        gate.open()
        #expect(await scanCleanup.value)
        #expect(await closing.value)
        #expect(stage.commissioner.restores == [camera.id], "one return per camera")
        #expect(stage.journal == nil)
    }

    @available(macOS 14, *)
    @Test func discoveryFollowsAddAndConnectDemand() async {
        typealias C = MultiviewCoordinator<FakeMemberLink>
        #expect(C.needsDiscovery(running: true, applicationActive: true, hasEmptySlot: true, connecting: false))
        #expect(!C.needsDiscovery(running: true, applicationActive: true, hasEmptySlot: false, connecting: false))
        #expect(C.needsDiscovery(running: true, applicationActive: false, hasEmptySlot: false, connecting: true))
        #expect(!C.needsDiscovery(running: true, applicationActive: false, hasEmptySlot: true, connecting: false))
        #expect(!C.needsDiscovery(running: false, applicationActive: true, hasEmptySlot: true, connecting: true))

        let stage = Fixture()
        let c = stage.coordinator
        c.start()
        await until { stage.scanner.scanning }
        let camera = FakeStationCamera(name: "Camera A")
        stage.scanner.see(camera)
        stage.scanner.see(camera)
        #expect(c.found == [camera], "a camera is listed once")
        c.setApplicationActive(false)
        await until { !stage.scanner.scanning }
        #expect(stage.scanner.stops >= 1, "an inactive app with nothing connecting stops scanning")
        c.setApplicationActive(true)
        await until { stage.scanner.scanning }
        #expect(stage.scanner.starts == 2)
        c.stop()
    }

    @available(macOS 14, *)
    @Test func linkStatusShowsTheTileCopyAndTheCoordinatorOwnsTheControlHost() {
        let stage = Fixture()
        let member = stage.coordinator.members[0]
        let link = stage.links[0]
        member.address = "192.0.2.41"
        member.failureMessage = MultiviewCopy.couldNotRestore
        link.onStatus?(.opening)
        #expect(member.status == "Connecting normal preview")
        #expect(member.controlHost == nil, "opening is not yet control")
        link.onStatus?(.controlling)
        #expect(member.controlHost == "192.0.2.41", "the coordinator records the address it opened")
        #expect(member.failureMessage == nil)
        #expect(stage.host.changes.contains { $0.slot == 0 && $0.change == .control })
        link.onStatus?(.awaitingPicture)
        #expect(member.status == "Waiting for video")
        link.onStatus?(.live)
        #expect(member.status == "Live · Video mode")
        link.onStatus?(.reconnecting)
        #expect(member.status == "Reconnecting…")
    }

    @available(macOS 14, *)
    @Test func addCommissionsJoinsAndFindsTheCameraByProbe() async {
        let stage = Fixture()
        await stage.configure()
        let camera = FakeStationCamera(name: "Camera A")
        stage.links[0].place(camera, at: "192.168.1.12")
        await stage.coordinator.add(camera, slot: 0)
        let member = stage.coordinator.members[0]
        #expect(stage.commissioner.connects == [camera.id])
        #expect(stage.commissioner.joins.first?.network == stage.coordinator.stationNetwork)
        #expect(stage.commissioner.linksClosed == 1, "the Bluetooth link closes before discovery")
        #expect(stage.links[0].probes == ["192.168.1.9", "192.168.1.11", "192.168.1.12", "192.168.1.13", "192.168.1.14"])
        #expect(stage.links[0].opens.map(\.address) == ["192.168.1.12"])
        #expect(stage.links[0].opens.first?.expecting == camera.identity)
        #expect(member.identity == camera.identity)
        #expect(member.controlHost == "192.168.1.12")
        #expect(member.publishing && member.networkVerified && !member.connecting)
        #expect(member.status == MultiviewCopy.waitingForVideo)
        #expect(member.failureMessage == nil)
        #expect(stage.savedNetworks.last == stage.coordinator.stationNetwork)
        #expect(stage.journal?.cameras.map(\.address) == ["192.168.1.12"])
        #expect(stage.journal?.cameras.first?.identity == camera.identity)
        stage.coordinator.stop()
    }

    @available(macOS 14, *)
    @Test func discoveryTriesTheKnownAddressFirstThenTwoPassesWithoutOtherMembers() async throws {
        let stage = Fixture()
        await stage.configure()
        let c = stage.coordinator
        let camera = FakeStationCamera(name: "Camera A")
        c.members[1].camera = FakeStationCamera(name: "Camera B")
        c.members[1].controlHost = "192.168.1.11"
        c.members[0].camera = camera
        c.members[0].identity = camera.identity
        c.members[0].address = "192.168.1.13"
        let reconnecting = Task { await c.connectPreview(slot: 0) }
        try await stage.clock.waitForSleeps(2)  // the 1 s monitor and the 3 s pause between passes
        stage.links[0].place(camera, at: "192.168.1.14")
        stage.clock.advance(by: .seconds(3))
        await reconnecting.value
        let pass = ["192.168.1.9", "192.168.1.12", "192.168.1.13", "192.168.1.14"]
        #expect(stage.links[0].opens.first?.address == "192.168.1.13", "the known address first")
        #expect(stage.links[0].probes == pass + pass, "two passes without this phone or other members")
        #expect(c.members[0].controlHost == "192.168.1.14")
        c.stop()
    }

    @available(macOS 14, *)
    @Test func anUnsupportedSubnetFailsTheAddWithItsCopy() async {
        let stage = Fixture(netmask: "255.255.0.0")
        await stage.configure()
        await stage.coordinator.add(FakeStationCamera(name: "Camera A"), slot: 0)
        #expect(stage.coordinator.members[0].failureMessage == MultiviewCopy.unsupportedSubnet)
        #expect(stage.coordinator.members[0].status == MultiviewCopy.couldNotConnect)
        stage.coordinator.stop()
    }

    @available(macOS 14, *)
    @Test func theDuplicateRefusalIsFinal() async {
        let stage = Fixture()
        await stage.configure()
        let c = stage.coordinator
        let camera = FakeStationCamera(name: "Camera A")
        c.members[1].camera = FakeStationCamera(name: "Camera B")
        c.members[1].identity = camera.identity  // the same body, already a member
        stage.links[0].place(camera, at: "192.168.1.12")
        await c.add(camera, slot: 0)
        #expect(c.members[0].failureMessage == MultiviewCopy.duplicate)
        #expect(stage.links[0].opens.map(\.address) == ["192.168.1.12"], "the search stops there")
        await c.reconnect(slot: 0)
        #expect(c.members[0].failureMessage == MultiviewCopy.duplicate)
        c.stop()
    }

    @available(macOS 14, *)
    @Test func aCameraWithoutPreviewStopsAtTheVerifiedJoin() async {
        let stage = Fixture()
        await stage.configure()
        let camera = FakeStationCamera(name: "NoPreview camera")
        stage.links[0].place(camera, at: "192.168.1.12")
        await stage.coordinator.add(camera, slot: 0)
        let member = stage.coordinator.members[0]
        #expect(member.status == MultiviewCopy.verifiedWithoutPreview)
        #expect(member.networkVerified && !member.publishing && member.failureMessage == nil)
        #expect(stage.links[0].starts == 0, "no picture is asked for")
        stage.coordinator.stop()
    }

    @available(macOS 14, *)
    @Test func reconnectTriesTheKnownCameraThenSetsItUpAgain() async throws {
        let stage = Fixture()
        await stage.configure()
        let c = stage.coordinator
        let camera = FakeStationCamera(name: "Camera A")
        stage.links[0].place(camera, at: "192.168.1.12")
        await c.add(camera, slot: 0)
        stage.links[0].answering = [:]  // the camera left the network
        let gate = FakeGate()
        stage.commissioner.connectGate = gate
        let reconnecting = Task { await c.reconnect(slot: 0) }
        try await stage.clock.waitForSleeps(2)
        stage.clock.advance(by: .seconds(3))
        await until { gate.waiting == 1 }
        #expect(stage.commissioner.connects.count == 2, "a failed search sets the camera up again")
        stage.links[0].place(camera, at: "192.168.1.13")
        gate.open()
        await reconnecting.value
        #expect(c.members[0].controlHost == "192.168.1.13")
        #expect(c.members[0].failureMessage == nil)
        #expect(c.members[0].camera == camera)
        c.stop()
    }

    @available(macOS 14, *)
    @Test func repairsRejoinWithinTheBudgetThenWaitForTheOperator() async throws {
        let stage = Fixture()
        let (c, link, member) = await stage.liveMember()
        link.repairStep = { _ in .repair { .rejoin } }
        for rejoin in 1...2 {
            try await stage.tick(.seconds(1))
            await until { link.opens.count == 1 + rejoin && !member.recovering }
            #expect(member.publishing, "rejoin \(rejoin) reopened the member")
        }
        try await stage.tick(.seconds(1))
        await until { member.failureMessage != nil }
        #expect(member.failureMessage == MultiviewCopy.couldNotRestore)
        #expect(member.budget.exhausted)
        let ticks = link.repairTicks
        try await stage.tick(.seconds(1))
        try await stage.clock.waitForSleeps(1)
        #expect(link.repairTicks == ticks, "an exhausted member waits for the operator")
        link.repairStep = { _ in .healthy }
        await c.reconnect(slot: 0)
        #expect(member.failureMessage == nil && member.publishing && !member.budget.exhausted)
        c.stop()
    }

    @available(macOS 14, *)
    @Test func aHealthyTransportRestoresTheBudget() async throws {
        let stage = Fixture()
        let (c, link, member) = await stage.liveMember()
        link.repairStep = { _ in .repair { .rejoin } }
        try await stage.tick(.seconds(1))
        await until { link.opens.count == 2 && !member.recovering }
        #expect(member.budget.used == 1)
        link.repairStep = { context in
            context.observeHealth(true)
            return .healthy
        }
        try await stage.tick(.seconds(1))
        await until { link.repairTicks == 2 }
        try await stage.tick(.seconds(31))
        await until { link.repairTicks == 3 }
        #expect(member.budget.used == 0, "30 s of a healthy transport restores the budget")
        c.stop()
    }

    @available(macOS 14, *)
    @Test func sharedNetworkLossFailsTheMemberAfter45Seconds() async throws {
        let stage = Fixture()
        let (c, link, member) = await stage.liveMember()
        stage.path.addresses[false] = nil
        try await stage.tick(.seconds(1))
        await until { link.repairTicks == 1 }
        try await stage.tick(.seconds(45))
        await until { link.repairTicks == 2 }
        #expect(member.failureMessage == nil, "45 s is still within the allowance")
        try await stage.tick(.seconds(1))
        await until { link.repairTicks == 3 }
        #expect(member.failureMessage == MultiviewCopy.sharedNetworkLost)
        #expect(member.budget.exhausted)
        c.stop()
    }

    @available(macOS 14, *)
    @Test func repairsWaitForTheForegroundGrace() async throws {
        let stage = Fixture()
        let (c, link, _) = await stage.liveMember()
        c.setApplicationActive(false)
        try await stage.tick(.seconds(1))
        await until { stage.host.ticks(of: link) }
        #expect(link.repairTicks == 0, "no repair while in the background")
        c.setApplicationActive(true)
        #expect(stage.host.activity == [false, true])
        for _ in 1...3 {
            try await stage.tick(.seconds(1))
            await until { link.keepalives >= 1 }
        }
        #expect(link.repairTicks == 0, "the first 3 s after a return belong to the pictures")
        try await stage.tick(.seconds(1))
        await until { link.repairTicks == 1 }
        c.stop()
    }

    @available(macOS 14, *)
    @Test func bluetoothTurnsWaitForAddsAndScansAndGoInOrder() async throws {
        let stage = Fixture()
        await stage.configure()
        let c = stage.coordinator
        for (slot, name) in ["Camera A", "Camera B"].enumerated() {
            let camera = FakeStationCamera(name: name)
            stage.links[slot].place(camera, at: "192.168.1.1\(slot + 2)")
            await c.add(camera, slot: slot)
        }
        let gate = FakeGate()
        stage.commissioner.connectGate = gate
        let third = FakeStationCamera(name: "Camera C")
        stage.links[2].place(third, at: "192.168.1.14")
        let adding = Task { await c.add(third, slot: 2) }
        await until { gate.waiting == 1 }
        var grants: [(slot: Int, connecting: Bool)] = []
        var holding = 0
        var overlapped = false
        for slot in 0...1 {
            stage.links[slot].repairStep = { context in
                .repair {
                    guard let release = await context.bluetoothTurn() else { return .done }
                    holding += 1
                    if holding > 1 { overlapped = true }
                    grants.append((slot, c.connectingCameras))
                    await Task.yield()
                    holding -= 1
                    release()
                    return .done
                }
            }
        }
        stage.clock.advance(by: .seconds(1))
        await until { c.members[0].recovering && c.members[1].recovering }
        for _ in 0..<20 { await Task.yield() }
        #expect(grants.isEmpty, "no turn while an add commissions a camera")
        gate.open()
        await adding.value
        await until { grants.count == 2 }
        #expect(grants.map(\.slot) == [0, 1], "turns go in request order")
        #expect(grants.allSatisfy { !$0.connecting })
        #expect(!overlapped, "one holder at a time")
        c.stop()
    }

    @available(macOS 14, *)
    @Test func recordAvailabilityFollowsThreeSecondFreshness() async throws {
        let stage = Fixture()
        let (c, link, member) = await stage.liveMember()
        link.recordReport = MultiviewRecordReport(recording: false, receivedAt: stage.clock.date)
        try await stage.tick(.seconds(1))
        await until { member.recordingAvailable }
        try await stage.tick(.seconds(2))
        await until { !member.recordingAvailable }
        #expect(c.tile(0, readings())?.actions.first { $0.id == MultiviewCameraAction.record }?.enabled == false)
        link.recordReport = MultiviewRecordReport(recording: false, receivedAt: stage.clock.date)
        try await stage.tick(.seconds(1))
        await until { member.recordingAvailable }
        #expect(c.tile(0, readings())?.actions.first { $0.id == MultiviewCameraAction.record }?.enabled == true)

        await link.fakeSession.cameraReportsStatus()
        await link.fakeSession.setLiveViewReady(true)
        await link.syncSnapshot()
        #expect(c.recordPlan(slot: nil).isExecutable)
        await link.fakeSession.cameraReportsRecording(nil)
        await link.syncSnapshot()
        #expect(c.recordPlan(slot: nil).isRefused, "strict: one unknown record state refuses all")
        #expect(!c.canRecordTogether)
        c.stop()
    }

    @available(macOS 14, *)
    @Test func recordWritesEachOutcomeOnItsMemberAndTheGroupSummary() async {
        let stage = Fixture()
        await stage.configure()
        let c = stage.coordinator
        for (slot, name) in ["Camera A", "Camera B"].enumerated() {
            let camera = FakeStationCamera(name: name)
            stage.links[slot].place(camera, at: "192.168.1.1\(slot + 2)")
            await c.add(camera, slot: slot)
            await stage.links[slot].fakeSession.cameraReportsStatus()
            await stage.links[slot].fakeSession.setLiveViewReady(true)
            await stage.links[slot].syncSnapshot()
        }
        let a = stage.links[0].fakeSession
        let b = stage.links[1].fakeSession
        await b.silenceReports(true)
        let plan = c.recordPlan(slot: nil)
        #expect(plan.direction == .start)
        let recording = Task { await c.record(plan, together: true) }
        await until { c.groupRecordingBusy }
        #expect(c.groupRecordingNote == "Starting cameras…")
        await untilAsync {
            let sentA = await a.wire
            let sentB = await b.wire
            return !sentA.isEmpty && !sentB.isEmpty
        }
        await a.advance(by: .seconds(1))
        await b.advance(by: .seconds(60))
        await recording.value
        #expect(c.members[0].recordingNote == "Recording")
        #expect(c.members[1].recordingNote == "No confirmation · check camera")
        #expect(c.groupRecordingNote == "1 of 2 confirmed · check camera tiles")
        #expect(!c.groupRecordingBusy)
        c.stop()
    }

    @available(macOS 14, *)
    @Test func theConfirmationWindowConfirmsRefusesOrTimesOut() async throws {
        let clock = ManualHostClock()
        func run(
            start: Bool = true, current: Bool = true, reply: Bool? = nil,
            report: MultiviewRecordReport? = nil, advance: Duration = .milliseconds(100)
        ) async throws -> (MultiviewRecordConfirmation.Outcome, Bool) {
            let sent = clock.date
            var acknowledged = false
            let waiting = Task { @MainActor in
                await MultiviewRecordConfirmation.wait(
                    start: start, sentAt: sent, clock: clock.clock, current: { current },
                    reply: { reply }, report: { report }, acknowledged: { acknowledged = true })
            }
            try await clock.waitForSleeps(1)
            clock.advance(by: advance)
            return (await waiting.value, acknowledged)
        }
        let later = { MultiviewRecordReport(recording: true, receivedAt: clock.date.addingTimeInterval(0.05)) }
        let confirmed = try await run(reply: true, report: later())
        #expect(confirmed.0 == .confirmed && confirmed.1)
        #expect(try await run(reply: false).0 == .refused)
        #expect(try await run(current: false).0 == .unconfirmed, "a replaced link ends the wait")
        #expect(try await run(advance: .seconds(8)).0 == .unconfirmed, "8 s without a report")
        let stale = MultiviewRecordReport(recording: true, receivedAt: clock.date.addingTimeInterval(-1))
        #expect(try await run(report: stale, advance: .seconds(8)).0 == .unconfirmed, "only a newer report confirms")
    }

    @available(macOS 14, *)
    @Test func liveViewNeedsAControlledMemberAndClosesTheEditorFirst() {
        let stage = Fixture()
        let c = stage.coordinator
        stage.host.opensLiveView = true
        c.members[0].camera = FakeStationCamera(name: "Camera A")
        #expect(!c.openLiveView(slot: 0), "no control path yet")
        #expect(stage.host.liveViews.isEmpty)
        #expect(stage.host.editorsClosed == 1, "the editor closes first")
        c.members[0].controlHost = "192.168.1.12"
        c.members[0].recovering = true
        #expect(!c.openLiveView(slot: 0), "not while the picture is restored")
        c.members[0].recovering = false
        #expect(c.openLiveView(slot: 0))
        #expect(stage.host.liveViews == [0])
    }

    @available(macOS 14, *)
    @Test func removeClearsTheMemberWithoutACameraCommand() async {
        let stage = Fixture()
        let (c, link, member) = await stage.liveMember()
        let camera = member.camera!
        member.recordingBusy = true
        #expect(!c.remove(slot: 0), "not while a record command waits")
        member.recordingBusy = false
        member.lutEnabled = false
        #expect(c.remove(slot: 0))
        #expect(member.camera == nil && member.identity == nil && member.controlHost == nil)
        #expect(member.status == MultiviewCopy.addCamera && member.lutEnabled && !member.publishing)
        #expect(link.closes >= 1)
        #expect(stage.host.changes.contains { $0.slot == 0 && $0.change == .removed })
        #expect(await link.fakeSession.wire.isEmpty, "removing never commands the camera")
        #expect(stage.journal?.cameras == [])
        let probes = link.probes.count
        await c.add(camera, slot: 0)
        #expect(link.opens.last?.address == "192.168.1.12", "the same camera again: its address first")
        #expect(link.probes.count == probes, "found there without a search")
        c.stop()
    }

    @available(macOS 14, *)
    @Test func tileValuesFollowPocketIOS() async {
        let stage = Fixture()
        let (c, link, member) = await stage.liveMember()
        #expect(c.tile(1, readings()) == nil, "an empty slot has no tile")
        link.recordReport = MultiviewRecordReport(recording: false, receivedAt: stage.clock.date)
        member.recordingAvailable = true
        var tile = c.tile(0, readings(hasPicture: true))
        #expect(tile?.status == nil)
        #expect(tile?.tally == "STBY")
        #expect(tile?.actions.map(\.id) == ["liveView", "record", "lut", "reconnect", "remove"])
        #expect(tile?.actions.allSatisfy(\.enabled) == true)
        member.recordingNote = "Recording"
        #expect(c.tile(0, readings(hasPicture: true))?.tileNote == nil, "plain confirmations stay off the tile")
        member.recordingNote = "No confirmation · check camera"
        #expect(c.tile(0, readings(hasPicture: true))?.tileNote == "No confirmation · check camera")

        member.recovering = true
        tile = c.tile(0, readings(hasPicture: true))
        #expect(tile?.status?.text == "Restoring picture…")
        #expect(tile?.status?.inProgress == true)
        #expect(tile?.tally == "HOLD")
        member.recovering = false

        member.identity = nil
        member.failureMessage = MultiviewCopy.couldNotRestore
        tile = c.tile(0, readings(hasPicture: true))
        #expect(tile?.status?.text == "Connection failed · Options")
        #expect(tile?.status?.detail == MultiviewCopy.couldNotRestore)
        #expect(tile?.status?.inProgress == false)
        #expect(tile?.tally == "CHECK")
        #expect(tile?.actions.map(\.id).contains("experimental") == true)

        member.failureMessage = nil
        member.camera = FakeStationCamera(name: "NoPreview camera")
        tile = c.tile(0, readings(hasPicture: false))
        #expect(tile?.footnote == "Remove this camera to enable group recording for your other cameras.")
        #expect(tile?.actions.first { $0.id == "lut" }?.enabled == false)
        #expect(tile?.actions.contains { $0.id == "reconnect" } == false)
        c.stop()
    }

    @available(macOS 14, *)
    @Test func withoutACommissionerTheCameraOpensAtItsSightingAndKeepsItsProvenIdentity() async {
        let stage = Fixture(commissioner: false, discoversByProbe: false)
        await stage.configure()
        let camera = FakeStationCamera(name: "Body A", sightedAt: "192.168.1.13")
        stage.links[0].place(camera, at: "192.168.1.13")
        await stage.coordinator.add(camera, slot: 0)
        let member = stage.coordinator.members[0]
        #expect(stage.links[0].opens.map(\.address) == ["192.168.1.13"])
        #expect(stage.links[0].opens.first?.expecting == nil, "a sighting has no proof to expect")
        #expect(member.identity == camera.identity, "the proof it gave is kept for Reconnect")
        #expect(member.controlHost == "192.168.1.13")
        #expect(stage.links[0].probes.isEmpty, "never probed")
        stage.coordinator.stop()
    }

    @available(macOS 14, *)
    @Test func withoutProbeDiscoveryARejoinReopensTheKnownAddressOnly() async {
        let stage = Fixture(commissioner: false, discoversByProbe: false)
        await stage.configure()
        let camera = FakeStationCamera(name: "Body A", sightedAt: "192.168.1.13")
        stage.links[0].place(camera, at: "192.168.1.13")
        await stage.coordinator.add(camera, slot: 0)
        stage.links[0].answering = [:]
        await stage.coordinator.connectPreview(slot: 0)
        #expect(stage.links[0].opens.map(\.address) == ["192.168.1.13", "192.168.1.13"])
        #expect(stage.links[0].probes.isEmpty)
        #expect(stage.coordinator.members[0].failureMessage == MultiviewCopy.couldNotRestore)
        stage.coordinator.stop()
    }

    @available(macOS 14, *)
    @Test func hostsCompareByTheirKey() async throws {
        let stage = Fixture(hostKey: true)
        await stage.configure()
        let c = stage.coordinator
        c.members[1].camera = FakeStationCamera(name: "Camera B")
        c.members[1].controlHost = "192.168.001.012"
        let camera = FakeStationCamera(name: "Camera A")
        stage.links[0].place(camera, at: "192.168.1.12")
        let adding = Task { await c.add(camera, slot: 0) }
        try await stage.clock.waitForSleeps(2)
        stage.clock.advance(by: .seconds(3))
        await adding.value
        #expect(!stage.links[0].probes.contains("192.168.1.12"), "another member's host, in another form")
        #expect(c.members[0].failureMessage == MultiviewCopy.notFound)
        c.stop()
    }

    @available(macOS 14, *)
    @Test func bluetoothTurnsResumeWhenAReconnectEnds() async throws {
        let stage = Fixture()
        await stage.configure()
        let c = stage.coordinator
        let b = FakeStationCamera(name: "Camera B")
        for (slot, camera) in [FakeStationCamera(name: "Camera A"), b].enumerated() {
            stage.links[slot].place(camera, at: "192.168.1.1\(slot + 2)")
            await c.add(camera, slot: slot)
        }
        let gate = FakeGate()
        stage.links[1].openGate = gate
        let reconnecting = Task { await c.connectPreview(slot: 1) }
        await until { gate.waiting == 1 }
        var granted = false
        stage.links[0].repairStep = { context in
            .repair {
                guard let release = await context.bluetoothTurn() else { return .done }
                granted = true
                release()
                return .done
            }
        }
        try await stage.tick(.seconds(1))
        await until { c.members[0].recovering }
        for _ in 0..<20 { await Task.yield() }
        #expect(!granted, "no turn while another member connects")
        gate.open()
        await reconnecting.value
        await until { granted }
        c.stop()
    }

    @available(macOS 14, *)
    @Test func aCancelledCloseStillEnds() async {
        let stage = Fixture()
        let gate = FakeGate()
        stage.commissioner.restoreGate = gate
        let camera = FakeStationCamera(name: "Scan camera")
        stage.coordinator.recordStationChange(camera)
        let closing = Task { await stage.coordinator.closeStage() }
        await until { gate.waiting == 1 }
        closing.cancel()
        gate.open()
        #expect(await closing.value, "the camera's return finishes for a cancelled caller")
        #expect(!stage.coordinator.closing)
        #expect(stage.journal == nil)
        #expect(await stage.coordinator.closeStage(), "the stage closes again")
    }

    @available(macOS 14, *)
    @Test func removeForgetsTheAddressForAnotherCamera() async {
        let stage = Fixture(commissioner: false, discoversByProbe: false)
        await stage.configure()
        let c = stage.coordinator
        let a = FakeStationCamera(name: "Body A", sightedAt: "192.168.1.12")
        let b = FakeStationCamera(name: "Body B", sightedAt: "192.168.1.13")
        stage.links[0].place(a, at: "192.168.1.12")
        stage.links[0].place(b, at: "192.168.1.13")
        await c.add(a, slot: 0)
        #expect(c.remove(slot: 0))
        #expect(c.members[0].address == "")
        await c.add(b, slot: 0)
        #expect(
            stage.links[0].opens.map(\.address) == ["192.168.1.12", "192.168.1.13"],
            "the new camera is never opened at the removed camera's address")
        #expect(c.members[0].identity == b.identity)
        c.stop()
    }

    @available(macOS 14, *)
    @Test func aMemberWhosePreviewStartedDuringItsJoinIsWatched() async throws {
        let stage = Fixture()
        await stage.configure()
        let c = stage.coordinator
        let gate = FakeGate()
        stage.commissioner.verifiesOnJoin = true
        stage.commissioner.afterVerifyGate = gate
        let camera = FakeStationCamera(name: "Camera A")
        stage.links[0].place(camera, at: "192.168.1.12")
        let adding = Task { await c.add(camera, slot: 0) }
        await until { gate.waiting == 1 }
        #expect(c.members[0].publishing && c.members[0].connecting)
        try await stage.tick(.seconds(1))
        await until { stage.links[0].keepalives >= 1 }
        #expect(stage.links[0].repairTicks == 1, "the watchdog runs while the join finishes")
        gate.open()
        await adding.value
        c.stop()
    }

    @available(macOS 14, *)
    @Test func aDuplicateFoundWhileTheCameraJoinsIsFinal() async {
        let stage = Fixture()
        await stage.configure()
        let c = stage.coordinator
        let camera = FakeStationCamera(name: "Camera A")
        c.members[1].camera = FakeStationCamera(name: "Camera B")
        c.members[1].identity = camera.identity  // the same body, already a member
        stage.commissioner.lostJoinReply = true
        stage.links[0].place(camera, at: "192.168.1.12")
        await c.add(camera, slot: 0)
        #expect(c.members[0].failureMessage == MultiviewCopy.duplicate)
        #expect(stage.links[0].opens.map(\.address) == ["192.168.1.12"], "the search stops there")
        c.stop()
    }

    @available(macOS 14, *)
    @Test func aRemovedMembersCancelledRepairChangesNothing() async throws {
        let stage = Fixture()
        let (c, link, member) = await stage.liveMember()
        let gate = FakeGate()
        var returned = false
        // A repair that ignores cancellation and gives up late.
        link.repairStep = { _ in
            .repair {
                await gate.wait()
                returned = true
                return .waitForOperator("Late verdict")
            }
        }
        try await stage.tick(.seconds(1))
        await until { gate.waiting == 1 && member.recovering }
        link.repairStep = { _ in .healthy }
        #expect(c.remove(slot: 0))
        gate.open()
        await until { returned }
        // The same camera comes back into the emptied slot.
        let camera = FakeStationCamera(name: "Camera A")
        link.place(camera, at: "192.168.1.12")
        await c.add(camera, slot: 0)
        #expect(member.failureMessage == nil, "a removed member's late verdict changes nothing")
        #expect(!member.budget.exhausted)
        #expect(member.publishing)
        c.stop()
    }

    @available(macOS 14, *)
    @Test func aReconnectSearchStartsNoRepairOnTheClosedLink() async throws {
        let stage = Fixture()
        await stage.configure()
        let c = stage.coordinator
        for (slot, name) in ["Camera A", "Camera B"].enumerated() {
            let camera = FakeStationCamera(name: name)
            stage.links[slot].place(camera, at: "192.168.1.1\(slot + 2)")
            await c.add(camera, slot: slot)
        }
        // B's known address now belongs to A's control path, and B answers nowhere: the search
        // waits between its passes with B's link closed.
        c.members[1].address = "192.168.1.12"
        stage.links[1].answering = [:]
        let reconnecting = Task { await c.reconnect(slot: 1) }
        try await stage.clock.waitForSleeps(2)
        let repairs = stage.links[1].repairTicks
        let ticks = stage.links[2].keepalives
        stage.clock.advance(by: .seconds(1))
        await until { stage.links[2].keepalives > ticks }
        #expect(stage.links[1].repairTicks == repairs, "no repair on a link the search closed")
        reconnecting.cancel()
        c.stop()
        await reconnecting.value
    }

    @available(macOS 14, *)
    @Test func anOlderRepairNeverClearsANewerOne() async throws {
        let stage = Fixture()
        let (c, link, member) = await stage.liveMember()
        let older = FakeGate()
        let newer = FakeGate()
        var olderReturned = false
        // The older repair ignores cancellation and ends only after the newer one started.
        link.repairStep = { _ in
            .repair {
                await older.wait()
                olderReturned = true
                return .done
            }
        }
        try await stage.tick(.seconds(1))
        await until { older.waiting == 1 }
        #expect(c.remove(slot: 0))
        let camera = FakeStationCamera(name: "Camera B")
        link.place(camera, at: "192.168.1.12")
        link.repairStep = { _ in
            .repair {
                await newer.wait()
                return .done
            }
        }
        await c.add(camera, slot: 0)
        try await stage.tick(.seconds(1))
        await until { newer.waiting == 1 && member.recovering }
        older.open()
        await until { olderReturned }
        try await stage.tick(.seconds(1))
        try await stage.clock.waitForSleeps(1)
        #expect(member.recovering, "the newer repair still owns the member")
        newer.open()
        await until { !member.recovering }
        c.stop()
    }

    @available(macOS 14, *)
    @Test func thePickerListsFoundCamerasThatMayJoinAndAreNotMembers() async {
        let stage = Fixture()
        await stage.configure()
        let c = stage.coordinator
        let a = FakeStationCamera(name: "Camera A")
        let limited = FakeStationCamera(name: "NoPreview B")
        let member = FakeStationCamera(name: "Camera M")
        c.members[1].camera = member
        c.found = [a, limited, FakeStationCamera(name: "Unqualified U"), member]
        #expect(
            c.pickerRows() == [
                MultiviewPickerRow(id: a.record.id.uuidString, title: "Camera A"),
                MultiviewPickerRow(
                    id: limited.record.id.uuidString, title: "NoPreview B",
                    detail: MultiviewCopy.previewUnavailable, limited: true),
            ])
        #expect(c.pickerFooter == "Each camera will join Test network. Approve on the camera if asked.")
        #expect(c.networkRestore == .cameraNetworks)
        #expect(!c.scansNetworks)
        stage.commissioner.scansNetworks = true
        #expect(c.scansNetworks)
        #expect(c.cameraName(slot: 1) == "Camera M")
        #expect(c.cameraName(slot: 0) == nil)
        c.stop()

        let passive = Fixture(commissioner: false, discoversByProbe: false)
        #expect(passive.coordinator.networkRestore == .none)
        #expect(!passive.coordinator.scansNetworks)
    }

    @available(macOS 14, *)
    @Test func pickingARowWithoutPreviewAddsItExperimentally() async {
        let stage = Fixture()
        await stage.configure()
        let c = stage.coordinator
        let camera = FakeStationCamera(name: "NoPreview B")
        stage.links[0].place(camera, at: "192.168.1.12")
        c.found = [camera]
        #expect(!c.enqueueAdd(pickerRow: UUID().uuidString, slot: 0), "an unknown row adds nothing")
        #expect(c.enqueueAdd(pickerRow: camera.record.id.uuidString, slot: 0))
        await until { c.members[0].networkVerified && !c.members[0].connecting }
        #expect(c.members[0].experimental)
        #expect(c.members[0].status == MultiviewCopy.verifiedWithoutPreview)
        #expect(c.pickerRows().isEmpty, "a member is no longer offered")
        c.stop()
    }

    @available(macOS 14, *)
    @Test func theExperimentalJoinShowsOnlyWhereTheCommissionerOffersIt() async {
        let stage = Fixture()
        await stage.configure()
        let c = stage.coordinator
        let limited = FakeStationCamera(name: "NoPreview B")
        c.found = [limited]
        c.members[0].camera = FakeStationCamera(name: "Camera A")
        c.members[0].failureMessage = MultiviewCopy.notFound
        let experimental: (MultiviewTile?) -> Bool = {
            $0?.actions.contains { $0.id == MultiviewCameraAction.experimental } == true
        }
        #expect(c.offersExperimentalJoin)
        #expect(experimental(c.stageTile(0)), "a failed camera may try the experimental path")
        stage.commissioner.joinsExperimentally = false
        #expect(!c.offersExperimentalJoin)
        #expect(!experimental(c.stageTile(0)), "a commissioner without it never offers it")
        #expect(
            c.pickerRows() == [
                MultiviewPickerRow(id: limited.record.id.uuidString, title: "NoPreview B", limited: true)
            ], "a camera without a picture joins the normal way, without the experimental copy")
        await c.tryExperimentalNetwork(slot: 0)
        #expect(c.members[0].camera != nil && stage.commissioner.joins.isEmpty, "nothing to try")
        stage.links[1].place(limited, at: "192.168.1.13")
        #expect(c.enqueueAdd(pickerRow: limited.record.id.uuidString, slot: 1))
        await until { !c.members[1].connecting && c.members[1].camera != nil }
        #expect(!c.members[1].experimental)
        #expect(stage.commissioner.joins.map(\.experimental) == [false])
        c.stop()

        let passive = Fixture(commissioner: false, discoversByProbe: false)
        passive.coordinator.members[0].camera = FakeStationCamera(name: "Body A")
        passive.coordinator.members[0].failureMessage = MultiviewCopy.notFound
        #expect(!passive.coordinator.offersExperimentalJoin)
        #expect(!experimental(passive.coordinator.stageTile(0)), "nothing to join through")
    }

    @available(macOS 14, *)
    @Test func anAddAsksForApprovalOnlyWhereTheCommissionerDoes() async {
        let stage = Fixture()
        await stage.configure()
        let c = stage.coordinator
        // The add's first status shows while this phone rejoins the network.
        let gate = FakeGate()
        stage.path.joinGate = gate
        let a = FakeStationCamera(name: "Camera A")
        stage.links[0].place(a, at: "192.168.1.12")
        let adding = Task { await c.add(a, slot: 0) }
        await until { gate.waiting == 1 }
        #expect(c.members[0].status == MultiviewCopy.approveOnCamera)
        #expect(c.pickerFooter == "Each camera will join Test network. Approve on the camera if asked.")
        gate.open()
        await adding.value
        stage.commissioner.asksApprovalOnCamera = false
        let b = FakeStationCamera(name: "Camera B")
        stage.links[1].place(b, at: "192.168.1.13")
        let gateB = FakeGate()
        stage.path.joinGate = gateB
        let addingB = Task { await c.add(b, slot: 1) }
        await until { gateB.waiting == 1 }
        #expect(c.members[1].status == MultiviewCopy.connectingPreview, "nothing asks on the camera")
        #expect(c.pickerFooter == "Each camera will join Test network.")
        gateB.open()
        await addingB.value
        c.stop()
    }

    @available(macOS 14, *)
    @Test func theScreenStartsTheStageAndOpensTheWizardFirst() {
        let stage = Fixture()
        let c = stage.coordinator
        #expect(c.choosesNetwork)
        #expect(c.screenAppeared(startsSession: true), "a new stage asks for its network")
        #expect(c.running && !c.networkConfigured)
        #expect(c.screenAppeared(startsSession: true), "appearing again starts nothing new")
        c.stop()

        let review = Fixture()
        review.coordinator.networkConfigured = true
        #expect(!review.coordinator.screenAppeared(startsSession: false))
        #expect(!review.coordinator.running, "a review fixture is never started")
    }

    @available(macOS 14, *)
    @Test func withoutACommissionerTheStageUsesThePhonesNetworkWithoutTheWizard() async {
        let passive = Fixture(commissioner: false, discoversByProbe: false)
        let c = passive.coordinator
        #expect(!c.choosesNetwork)
        #expect(!c.screenAppeared(startsSession: true), "no network wizard")
        #expect(c.running && c.networkConfigured, "cameras already share this phone's network")
        #expect(c.pickerFooter == "Cameras on this phone\u{2019}s network appear here.")
        let camera = FakeStationCamera(name: "Body A", sightedAt: "192.168.1.13")
        passive.links[0].place(camera, at: "192.168.1.13")
        await c.add(camera, slot: 0)
        #expect(c.members[0].controlHost == "192.168.1.13")
        #expect(passive.path.joins.isEmpty, "the phone stays on its own network")
        c.stop()
    }

    @available(macOS 14, *)
    @Test func aRemoveQueuedBeforeTheVerdictLandsChangesNothing() async throws {
        let stage = Fixture()
        let (c, link, member) = await stage.liveMember()
        let gate = FakeGate()
        var returned = false
        // The operator's Remove reaches the main actor before the repair's verdict does.
        link.repairStep = { _ in
            .repair {
                await gate.wait()
                Task { @MainActor in _ = c.remove(slot: 0) }
                returned = true
                return .waitForOperator("Late verdict")
            }
        }
        try await stage.tick(.seconds(1))
        await until { gate.waiting == 1 && member.recovering }
        link.repairStep = { _ in .healthy }
        gate.open()
        await until { returned && member.camera == nil }
        let camera = FakeStationCamera(name: "Camera A")
        link.place(camera, at: "192.168.1.12")
        await c.add(camera, slot: 0)
        #expect(member.failureMessage == nil, "the removed member's verdict changes nothing")
        #expect(!member.budget.exhausted)
        #expect(member.publishing)
        c.stop()
    }

    @available(macOS 14, *)
    @Test func lutTogglesFollowTheMembersAndTheJournal() async {
        let stage = Fixture()
        await stage.configure()
        let c = stage.coordinator
        c.members[0].camera = FakeStationCamera(name: "Camera A")
        c.members[1].camera = FakeStationCamera(name: "Camera B")
        #expect(c.lutOn)
        c.toggleLUT(slot: 0)
        #expect(!c.members[0].lutEnabled && c.members[1].lutEnabled)
        #expect(stage.host.lutChanges == [0])
        #expect(stage.journal?.cameras.map(\.lutEnabled) == [false, true])
        #expect(c.lutOn, "one camera still grades its picture")
        c.toggleLUT()
        #expect(c.members[0].lutEnabled && c.members[1].lutEnabled, "a mixed stage turns every LUT on")
        #expect(stage.host.lutChanges == [0, 0])
        c.toggleLUT()
        #expect(!c.members[0].lutEnabled && !c.members[1].lutEnabled)
        #expect(stage.host.lutChanges == [0, 0, 0, 1])
        #expect(!c.lutOn)
        #expect(stage.journal?.cameras.map(\.lutEnabled) == [false, false])
        c.stop()
    }

    @available(macOS 14, *)
    @Test func stageTilesUseTheHostsReadingsAndCapabilities() async {
        let stage = Fixture()
        let c = stage.coordinator
        c.members[0].camera = FakeStationCamera(name: "Camera A")
        c.members[1].camera = FakeStationCamera(name: "Camera B")
        let readouts = [MultiviewReadout(title: "ISO", value: "800")]
        stage.host.readings[0] = MultiviewTileReadings(
            name: "Wide", readouts: readouts, hasPicture: true)
        #expect(c.stageTile(0)?.name == "Wide")
        #expect(c.stageTile(1)?.name == "Camera B", "without readings the tile names its camera")
        #expect(c.stageTile(2) == nil)
        #expect(c.stageTile(0)?.actions.contains { $0.id == MultiviewCameraAction.lut } == false)
        #expect(c.toolAvailability == MultiviewToolAvailability())
        stage.host.autoLUT = true
        stage.host.edits = true
        #expect(c.stageTile(0)?.actions.contains { $0.id == MultiviewCameraAction.lut } == true)
        #expect(
            c.toolAvailability
                == MultiviewToolAvailability(cameraSettingsSlots: [0, 1], pictureLUTSlots: [0, 1]))
        #expect(c.cameraSettingsSlots == [0, 1])
        c.presentation.selected = 0
        #expect(c.programReadouts == readouts)
        c.presentation.selected = 2
        #expect(c.programReadouts == nil, "an empty program slot shows no values")
    }

    @available(macOS 14, *)
    @Test func controlsWaitForWhatOnlyTheAppAdmits() async {
        let stage = Fixture()
        let (c, _, member) = await stage.liveMember()
        member.recordingAvailable = true
        #expect(c.controlsAvailable(slot: 0))
        stage.host.admits = false
        #expect(!c.controlsAvailable(slot: 0), "the app's own link or Live View decides too")
        c.stop()
    }

    @available(macOS 14, *)
    @Test func aCancelledConfirmationWaitEndsAtOnce() async {
        let counter = SleepCounter()
        // Every sleep throws, as a cancelled task's does; the clock moves 1 ms per reading.
        let clock = HostClock(
            now: { counter.tick() }, date: { Date(timeIntervalSinceReferenceDate: 0) },
            sleep: { _ in
                counter.sleeps += 1
                throw CancellationError()
            })
        let outcome = await MultiviewRecordConfirmation.wait(
            start: true, sentAt: .distantPast, clock: clock, current: { true }, reply: { nil },
            report: { nil }, acknowledged: {})
        #expect(outcome == .unconfirmed)
        #expect(counter.sleeps == 1, "a cancelled wait ends instead of polling out the window")
    }
}

/// A clock reading count and the sleeps asked of it.
private final class SleepCounter: @unchecked Sendable {
    var sleeps = 0
    private var readings = 0

    func tick() -> MonotonicInstant {
        readings += 1
        return MonotonicInstant(.milliseconds(readings))
    }
}

// MARK: Fixture

private func journalCamera(slot: Int) -> MultiviewStageJournal.Camera {
    MultiviewStageJournal.Camera(
        slot: slot, id: UUID(), name: "Camera-Test", modelId: nil, identity: nil, address: "",
        experimental: false, lutEnabled: false)
}

private func readings(hasPicture: Bool = true) -> MultiviewTileReadings {
    MultiviewTileReadings(name: "Camera", hasPicture: hasPicture)
}

/// Yields until `condition` holds (bounded, so a broken expectation fails instead of hanging).
@MainActor private func until(
    _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
) async {
    for _ in 0..<20_000 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("condition never held", sourceLocation: sourceLocation)
}

@MainActor private func untilAsync(
    _ condition: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation
) async {
    for _ in 0..<20_000 {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("condition never held", sourceLocation: sourceLocation)
}

@MainActor
private final class RecordingHost: MultiviewHost {
    var changes: [(slot: Int, change: MultiviewMemberChange)] = []
    var activity: [Bool] = []
    var liveViews: [Int] = []
    var editorsClosed = 0
    var opensLiveView = false
    var readings: [Int: MultiviewTileReadings] = [:]
    var lutChanges: [Int] = []
    var autoLUT = false
    var edits = false
    var admits = true

    var appliesAutoLUT: Bool { autoLUT }
    var editsCameraSettings: Bool { edits }
    func readings(slot: Int) -> MultiviewTileReadings? { readings[slot] }
    func lutChanged(slot: Int) { lutChanges.append(slot) }
    func admitsControls(slot: Int) -> Bool { admits }

    func openLiveView(slot: Int) -> Bool {
        guard opensLiveView else { return false }
        liveViews.append(slot)
        return true
    }
    func closeEditors() { editorsClosed += 1 }
    func memberChanged(slot: Int, _ change: MultiviewMemberChange) { changes.append((slot, change)) }
    func applicationActivityChanged(_ active: Bool) { activity.append(active) }
    /// A monitor tick reached `link` (its keepalive ran).
    func ticks(of link: FakeMemberLink) -> Bool { link.keepalives > 0 }
}

/// One coordinator over fakes: four slots on 192.168.1.8/29 (this phone .10), on a manual clock.
@available(macOS 14, *)
@MainActor
private final class Fixture {
    let clock = ManualHostClock()
    let path: FakeStationHostPath
    let commissioner = FakeStationCommissioner()
    let scanner = FakeNearbyScanner()
    let links = (0..<4).map { _ in FakeMemberLink() }
    let host = RecordingHost()
    var journal: MultiviewStageJournal.Stage?
    var passwords: [String: String] = [:]
    var lookups: [(ssid: String, hotspot: Bool)] = []
    var savedNetworks: [StationNetwork] = []
    private var built: MultiviewCoordinator<FakeMemberLink>!
    var coordinator: MultiviewCoordinator<FakeMemberLink> { built }

    init(
        saved: MultiviewStageJournal.Stage? = nil, netmask: String = "255.255.255.248",
        commissioner withCommissioner: Bool = true, discoversByProbe: Bool = true,
        hostKey: Bool = false
    ) {
        path = FakeStationHostPath(netmask: netmask)
        journal = saved
        let normalized: @Sendable (String) -> String = {
            $0.split(separator: ".").map { String(Int($0) ?? 0) }.joined(separator: ".")
        }
        let policy = MultiviewCameraPolicy<FakeStationCamera>(
            discoversByProbe: discoversByProbe,
            hostKey: hostKey ? normalized : nil,
            qualification: { camera, _ -> MulticamQualification in
                camera.name.hasPrefix("Unqualified") ? .refused(.unsupportedConfiguration) : .qualified
            },
            hasPreview: { !$0.name.hasPrefix("NoPreview") })
        let commissioning: (any StationCommissioner<FakeStationCamera>)? =
            withCommissioner ? commissioner : nil
        let describe: @MainActor (FakeStationCamera) -> StationCameraRecord = { $0.record }
        let sighting: @MainActor (FakeStationCamera) -> String? = { $0.sightedAt }
        built = MultiviewCoordinator<FakeMemberLink>(
            links: links, policy: policy, commissioner: commissioning,
            scanner: scanner, hostPath: path, describe: describe,
            journal: MultiviewJournalStorage(
                load: { [unowned self] in self.journal },
                save: { [unowned self] in
                    self.journal = $0
                    return true
                }),
            networks: MultiviewNetworkStorage(
                password: { [unowned self] ssid, hotspot in
                    self.lookups.append((ssid, hotspot))
                    return self.passwords["\(ssid)|\(hotspot)"]
                },
                save: { [unowned self] in self.savedNetworks.append($0) }),
            sightingAddress: sighting, clock: clock.clock)
        built.host = host
    }

    /// Starts the stage and connects it to "Test network" over Wi-Fi.
    func configure() async {
        coordinator.start()
        coordinator.selectNetworkSource(hotspot: false)
        coordinator.selectNetwork("Test network")
        let configured = await coordinator.configureNetwork()
        #expect(configured)
    }

    /// Waits for the monitor to park its next sleep, then moves the clock by `duration`.
    func tick(_ duration: Duration) async throws {
        try await clock.waitForSleeps(1)
        clock.advance(by: duration)
    }

    /// A configured stage with Camera A live in slot 0 at 192.168.1.12.
    func liveMember() async -> (
        MultiviewCoordinator<FakeMemberLink>, FakeMemberLink, MultiviewMember<FakeStationCamera>
    ) {
        await configure()
        let camera = FakeStationCamera(name: "Camera A")
        links[0].place(camera, at: "192.168.1.12")
        await coordinator.add(camera, slot: 0)
        #expect(coordinator.members[0].publishing)
        return (coordinator, links[0], coordinator.members[0])
    }
}
