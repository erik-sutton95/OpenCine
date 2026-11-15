import Foundation
import Insta360Apple
import Insta360AppleTestSupport
import OpenCineCore
import OpenCineCoreTestSupport
import Testing

/// One Luna member on a Multiview stage: the probe, the LAN-only open with the serial checked, the
/// picture and record reports, Luna's repair (in place, then found again, Bluetooth only in the
/// coordinator's turn) and the Auto LUT source. Kotlin mirror: `LunaMemberLinkTest`, same names.
@MainActor @Suite struct LunaMemberLinkTests {
    private static let peripheral = UUID(uuidString: "6D5F1C2A-0000-4000-8000-00000000000A")!
    private static let sighting = NearbyCamera(
        id: peripheral.uuidString, name: "Luna A1B2", model: "Insta360 Luna Ultra",
        routes: [.cameraAccessPoint])
    private static let studio = StationNetwork(ssid: "Studio", password: "synthetic1", hotspot: false)
    private static let lunaA = LunaMultiview.identity(serial: "LUNA-A")

    /// A link whose camera LUNA-A answers at 192.168.1.31, opened and previewing.
    private static func live(_ port: FakeLunaStationPort, clock: HostClock = .live) async throws
        -> LunaMemberLink
    {
        port.cameras["192.168.1.31"] = "LUNA-A"
        port.answering = ["192.168.1.31"]
        let link = LunaMemberLink(port: port, clock: clock)
        _ = try await link.open(Self.sighting, at: "192.168.1.31", expecting: Self.lunaA, on: Self.studio)
        try await link.startPreview(Self.sighting)
        return link
    }

    @Test func openChecksTheSerialAtTheAddress() async throws {
        let port = FakeLunaStationPort()
        port.cameras["192.168.1.31"] = "LUNA-A"
        let link = LunaMemberLink(port: port)
        let proven = try await link.open(
            Self.sighting, at: "192.168.1.31", expecting: Self.lunaA, on: Self.studio)
        #expect(proven == Self.lunaA)
        #expect(port.steps == [.connect(Self.peripheral, host: "192.168.1.31", serial: "LUNA-A")])

        port.cameras["192.168.1.32"] = "LUNA-B"
        await #expect(throws: ConnectionFailure.self) {
            _ = try await link.open(
                Self.sighting, at: "192.168.1.32", expecting: Self.lunaA, on: Self.studio)
        }
    }

    @Test func openWithoutAnIdentityIsRefused() async {
        let port = FakeLunaStationPort()
        port.cameras["192.168.1.31"] = "LUNA-A"
        let link = LunaMemberLink(port: port)
        await #expect(throws: ConnectionFailure.self) {
            _ = try await link.open(Self.sighting, at: "192.168.1.31", expecting: nil, on: Self.studio)
        }
        #expect(!port.steps.contains { if case .connect = $0 { true } else { false } })
    }

    @Test func aSilentAddressFails() async {
        let link = LunaMemberLink(port: FakeLunaStationPort())
        await #expect(throws: ConnectionFailure.self) {
            _ = try await link.open(
                Self.sighting, at: "192.168.1.40", expecting: Self.lunaA, on: Self.studio)
        }
    }

    @Test func anAddressAnotherConnectionHoldsIsNeverOpened() async {
        let port = FakeLunaStationPort()
        port.cameras["192.168.1.31"] = "LUNA-A"
        port.stationHostsInUse = { ["192.168.1.31"] }
        let link = LunaMemberLink(port: port)
        await #expect(throws: ConnectionFailure.self) {
            _ = try await link.open(
                Self.sighting, at: "192.168.1.31", expecting: Self.lunaA, on: Self.studio)
        }
        #expect(port.steps.isEmpty)
    }

    @Test func probeAsksThePortOnly() async {
        let port = FakeLunaStationPort()
        port.answering = ["192.168.1.31"]
        let link = LunaMemberLink(port: port)
        #expect(await link.probe("192.168.1.31", on: Self.studio))
        #expect(!(await link.probe("192.168.1.32", on: Self.studio)))
        #expect(port.steps == [.probe("192.168.1.31"), .probe("192.168.1.32")])
    }

    @Test func startPreviewReportsControllingThenLive() async throws {
        let port = FakeLunaStationPort()
        port.cameras["192.168.1.31"] = "LUNA-A"
        let link = LunaMemberLink(port: port)
        var statuses: [MultiviewLinkStatus] = []
        link.onStatus = { statuses.append($0) }
        _ = try await link.open(Self.sighting, at: "192.168.1.31", expecting: Self.lunaA, on: Self.studio)
        port.secondsSinceVideo = nil
        try await link.startPreview(Self.sighting)
        #expect(statuses == [.opening, .controlling, .awaitingPicture])
        #expect(link.pictureHealth == .starting)
        port.secondsSinceVideo = 0.1
        await link.keepalive()
        #expect(statuses == [.opening, .controlling, .awaitingPicture, .live])
        #expect(link.pictureHealth == .live)
    }

    @Test func theRecordReportFollowsTheCamera() async throws {
        let time = ManualHostClock()
        let port = FakeLunaStationPort()
        let link = try await Self.live(port, clock: time.clock)
        #expect(link.recordReport == nil)
        port.camera.captureState = 1
        port.camera.reportCapture()
        await link.keepalive()
        #expect(link.recordReport == MultiviewRecordReport(recording: true, receivedAt: time.date))
        time.advance(by: .seconds(5))
        await link.keepalive()
        // No new report: the stamp stays, so the stage sees it go stale.
        #expect(link.recordReport?.receivedAt == Date(timeIntervalSinceReferenceDate: 0))
        port.camera.captureState = 0
        port.camera.reportCapture()
        await link.keepalive()
        #expect(link.recordReport == MultiviewRecordReport(recording: false, receivedAt: time.date))
        link.close()
        #expect(link.recordReport == nil)
    }

    @Test func aStallRestartsLiveInPlace() async throws {
        let time = ManualHostClock()
        let port = FakeLunaStationPort()
        let link = try await Self.live(port, clock: time.clock)
        var statuses: [MultiviewLinkStatus] = []
        link.onStatus = { statuses.append($0) }
        port.secondsSinceVideo = 3
        guard case .handled = link.repair(MultiviewRepairContext()) else {
            Issue.record("a short stall asks for a keyframe")
            return
        }
        port.secondsSinceVideo = 7
        guard case .repair(let restart) = link.repair(MultiviewRepairContext()) else {
            Issue.record("a longer stall restarts live")
            return
        }
        #expect(await restart() == .done)
        #expect(port.steps.contains(.restartLive))
        #expect(!port.steps.contains { if case .authorize = $0 { true } else { false } })
        // The tile reads Reconnecting while live restarts, then Live again once the picture returns.
        #expect(statuses == [.reconnecting])
        port.secondsSinceVideo = 0.2
        await link.keepalive()
        #expect(statuses == [.reconnecting, .live])
        #expect(link.pictureHealth == .live)
    }

    @Test func aRepairCancelledInItsBluetoothTurnReleasesTheTurn() async throws {
        let port = FakeLunaStationPort()
        let link = try await Self.live(port)
        port.dropLink()
        port.answering = []
        var released = false
        let context = MultiviewRepairContext(bluetoothTurn: { { released = true } })
        guard case .repair(let work) = link.repair(context) else {
            Issue.record("a lost link repairs")
            return
        }
        port.during = { step in
            if case .authorize = step { try? await Task.sleep(for: .seconds(3600)) }
        }
        let running = Task { await work() }
        while !port.steps.contains(where: { if case .authorize = $0 { true } else { false } }) {
            await Task.yield()
        }
        running.cancel()
        _ = await running.value
        #expect(released, "the coordinator's Bluetooth turn is released")
        #expect(!port.bluetoothOpen)
    }

    @Test func aLostLinkThatStillAnswersRejoinsWithoutBluetooth() async throws {
        let port = FakeLunaStationPort()
        let link = try await Self.live(port)
        port.dropLink()
        var turns = 0
        let context = MultiviewRepairContext(bluetoothTurn: {
            turns += 1
            return {}
        })
        guard case .repair(let work) = link.repair(context) else {
            Issue.record("a lost link repairs")
            return
        }
        #expect(await work() == .rejoin)
        #expect(turns == 0)
        #expect(!port.steps.contains { if case .authorize = $0 { true } else { false } })
    }

    @Test func aLostLinkMovesTheCameraUnderABluetoothTurn() async throws {
        let port = FakeLunaStationPort()
        let link = try await Self.live(port)
        port.dropLink()
        port.answering = []
        var held = false
        var released = false
        let context = MultiviewRepairContext(bluetoothTurn: {
            held = true
            return { released = true }
        })
        guard case .repair(let work) = link.repair(context) else {
            Issue.record("a lost link repairs")
            return
        }
        port.during = { step in
            if case .authorize = step { #expect(held && !released) }
        }
        #expect(await work() == .rejoin)
        #expect(released)
        #expect(port.steps.suffix(2) == [
            .authorize(Self.peripheral),
            .move(LunaStationNetwork(ssid: "Studio", password: "synthetic1", hotspot: false)),
        ])
    }

    @Test func aCameraThatRefusesThisPhoneWaitsForTheOperator() async throws {
        let port = FakeLunaStationPort()
        let link = try await Self.live(port)
        port.dropLink()
        port.answering = []
        let refusal = FakeLunaStationPort.failure(.heldElsewhere, "approval.held-elsewhere")
        port.authorizeFailure = refusal
        guard case .repair(let work) = link.repair(MultiviewRepairContext()) else {
            Issue.record("a lost link repairs")
            return
        }
        #expect(await work() == .waitForOperator(refusal.message))
    }

    @Test func aStoppedStageGetsNoBluetoothTurn() async throws {
        let port = FakeLunaStationPort()
        let link = try await Self.live(port)
        port.dropLink()
        port.answering = []
        guard case .repair(let work) = link.repair(MultiviewRepairContext(bluetoothTurn: { nil }))
        else {
            Issue.record("a lost link repairs")
            return
        }
        #expect(await work() == .done)
        #expect(!port.steps.contains { if case .authorize = $0 { true } else { false } })
    }

    @Test func aLostSharedNetworkLeavesTheRuleToTheStage() async throws {
        let port = FakeLunaStationPort()
        let link = try await Self.live(port)
        port.dropLink()
        guard case .healthy = link.repair(MultiviewRepairContext(pathReady: false)) else {
            Issue.record("the coordinator's path rule decides")
            return
        }
    }

    @Test func closeSendsNoCameraCommand() async throws {
        let port = FakeLunaStationPort()
        let link = try await Self.live(port)
        link.close()
        #expect(port.steps.last == .disconnect)
        #expect(port.camera.sent.isEmpty)
        #expect(link.pictureHealth == .failed)
    }

    @Test func theSessionIsOnePerMember() async throws {
        let port = FakeLunaStationPort()
        let link = try await Self.live(port)
        let first = link.session.id
        link.close()
        _ = try await link.open(Self.sighting, at: "192.168.1.31", expecting: Self.lunaA, on: Self.studio)
        #expect(link.session.id == first)
        #expect(port.sessionsOpened == 1)
    }

    @Test func autoLUTFollowsTheColorProfile() async throws {
        let port = FakeLunaStationPort()
        port.cameras["192.168.1.31"] = "LUNA-A"
        let link = LunaMemberLink(
            port: port, conversion: { $0 == "I-Log" ? "I-Log to Rec.709" : nil })
        #expect(link.autoLUT == MultiviewAutoLUT(colorMode: nil, conversion: nil))
        _ = try await link.open(Self.sighting, at: "192.168.1.31", expecting: Self.lunaA, on: Self.studio)
        port.camera.colorMode = 2
        port.camera.reportSettings()
        #expect(link.autoLUT.colorMode == "I-Log")
        #expect(link.autoLUT.conversion == "I-Log to Rec.709")
    }

    @Test func autoLUTFollowsWhatThePictureCarries() async throws {
        // Color Recovery grades the I-Log feed before it reaches the phone: the app's preview rule
        // says the picture is Standard, so no conversion runs on top of it.
        let port = FakeLunaStationPort()
        port.cameras["192.168.1.31"] = "LUNA-A"
        let link = LunaMemberLink(
            port: port, conversion: { $0 == "I-Log" ? "I-Log to Rec.709" : nil },
            preview: { $0 == "I-Log" ? "Standard" : $0 })
        _ = try await link.open(Self.sighting, at: "192.168.1.31", expecting: Self.lunaA, on: Self.studio)
        port.camera.colorMode = 2
        port.camera.reportSettings()
        #expect(link.autoLUT == MultiviewAutoLUT(colorMode: "Standard", conversion: nil))
        #expect(link.autoLUT.caption(enabled: true, conversionLoaded: false) == "Auto · no conversion needed")
    }
}
