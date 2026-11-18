import Foundation
import Insta360Apple
import Insta360AppleTestSupport
import OpenCineCore
import OpenCineCoreTestSupport
import Testing

/// Luna on a Multiview stage: which sightings join, the commission over Bluetooth (serial, station
/// move, the verification window) and the return to the access point. Kotlin mirror:
/// `LunaMultiviewTest`, same method names.
@MainActor @Suite struct LunaMultiviewTests {
    private static let peripheral = UUID(uuidString: "6D5F1C2A-0000-4000-8000-00000000000A")!
    private static let sighting = NearbyCamera(
        id: peripheral.uuidString, name: "Luna A1B2", model: "Insta360 Luna Ultra",
        routes: [.cameraAccessPoint])
    private static let studio = StationNetwork(ssid: "Studio", password: "synthetic1", hotspot: false)

    /// A commissioner whose every port is `port`.
    private static func commissioner(_ port: FakeLunaStationPort, clock: HostClock = .live)
        -> LunaStationCommissioner
    {
        LunaStationCommissioner(makePort: { port }, clock: clock)
    }

    @Test func anAvailableLunaJoinsWithItsPictureAndABusyOneIsNotOffered() {
        let policy = LunaMultiview.policy
        #expect(policy.qualification(Self.sighting, experimental: false) == .qualified)
        #expect(policy.hasPreview(Self.sighting))
        #expect(policy.discoversByProbe)
        var busy = Self.sighting
        busy.availability = .unavailable(.busy)
        #expect(policy.qualification(busy, experimental: false) == .refused(.operationUnavailable))
        #expect(
            policy.qualification(Self.sighting, experimental: true)
                == .refused(.unsupportedConfiguration))
    }

    @Test func aSightingIsJournaledByItsPeripheral() {
        let record = LunaMultiview.record(Self.sighting)
        #expect(record.id == Self.peripheral)
        #expect(record.name == "Luna A1B2")
        #expect(record.modelId == nil)
        #expect(LunaMultiview.serial(identity: LunaMultiview.identity(serial: "LUNA-A")) == "LUNA-A")
    }

    @Test func theCommissionerAsksForApprovalAndHasNoExperimentalPath() {
        let commissioner = Self.commissioner(FakeLunaStationPort())
        #expect(commissioner.asksApprovalOnCamera)
        #expect(!commissioner.joinsExperimentally)
        #expect(!commissioner.scansNetworks)
    }

    @Test func aCommissionProvesTheSerialAndMovesTheCamera() async throws {
        let port = FakeLunaStationPort()
        port.serial = "LUNA-A"
        let commission = try await Self.commissioner(port).connect(Self.sighting) { _ in }
        #expect(port.steps == [.authorize(Self.peripheral)])
        let identity = try await commission.identity()
        #expect(identity == Array("LUNA-A".utf8))
        var progress: [String] = []
        var asked = 0
        let outcome = try await commission.join(
            Self.studio, identity: identity, experimental: false, progress: { progress.append($0) },
            verifyOnNetwork: {
                asked += 1
                return true
            })
        #expect(outcome == .verified)
        #expect(asked == 1)
        #expect(port.steps == [
            .authorize(Self.peripheral),
            .move(LunaStationNetwork(ssid: "Studio", password: "synthetic1", hotspot: false)),
        ])
        #expect(progress == ["Moving the camera to “Studio”…"])
        #expect(!port.bluetoothOpen)
    }

    @Test func aCameraNotFoundYetIsAskedAgainWithinTheBudget() async throws {
        let time = ManualHostClock()
        let port = FakeLunaStationPort()
        let commission = try await Self.commissioner(port, clock: time.clock).connect(Self.sighting) { _ in }
        var asked = 0
        let join = Task {
            try await commission.join(
                Self.studio, identity: [], experimental: false, progress: { _ in },
                verifyOnNetwork: {
                    asked += 1
                    if asked < 3 { throw CameraNotFound() }
                    return true
                })
        }
        try await time.waitForSleeps(1)
        time.advance(by: LunaStationCommissioner.verifyInterval)
        try await time.waitForSleeps(1)
        time.advance(by: LunaStationCommissioner.verifyInterval)
        #expect(try await join.value == .verified)
        #expect(asked == 3)
    }

    @Test func aCameraStillMissingAfterTheBudgetLeavesTheSearchToTheStage() async throws {
        let time = ManualHostClock()
        let port = FakeLunaStationPort()
        let commission = try await Self.commissioner(port, clock: time.clock).connect(Self.sighting) { _ in }
        let join = Task {
            try await commission.join(
                Self.studio, identity: [], experimental: false, progress: { _ in },
                verifyOnNetwork: { false })
        }
        let tries = Int(LunaStationCommissioner.verifyBudget / LunaStationCommissioner.verifyInterval)
        for _ in 1..<tries {
            try await time.waitForSleeps(1)
            time.advance(by: LunaStationCommissioner.verifyInterval)
        }
        #expect(try await join.value == .joined)
    }

    @Test func aFinalVerificationEndsTheJoin() async throws {
        let port = FakeLunaStationPort()
        let commission = try await Self.commissioner(port).connect(Self.sighting) { _ in }
        var asked = 0
        await #expect(throws: StationVerifyFinal.self) {
            _ = try await commission.join(
                Self.studio, identity: [], experimental: false, progress: { _ in },
                verifyOnNetwork: {
                    asked += 1
                    throw StationVerifyFinal(CameraNotFound())
                })
        }
        #expect(asked == 1)
    }

    @Test func aRefusedApprovalClosesBluetoothAndFailsTheAdd() async {
        let port = FakeLunaStationPort()
        port.authorizeFailure = FakeLunaStationPort.failure(.notApproved, "approval.declined")
        await #expect(throws: ConnectionFailure.self) {
            _ = try await Self.commissioner(port).connect(Self.sighting) { _ in }
        }
        #expect(!port.bluetoothOpen)
        #expect(!port.steps.contains { if case .move = $0 { true } else { false } })
    }

    @Test func closingACommissionClosesBluetooth() async throws {
        let port = FakeLunaStationPort()
        let commissioner = Self.commissioner(port)
        _ = try await commissioner.connect(Self.sighting) { _ in }
        #expect(port.bluetoothOpen)
        commissioner.closeCommissions()
        #expect(!port.bluetoothOpen)
        #expect(port.steps.last == .disconnect)
    }

    @Test func returnMapsEveryResult() async {
        let record = LunaMultiview.record(Self.sighting)
        let returned = FakeLunaStationPort()
        #expect(await Self.commissioner(returned).restoreAccessPoint(record) == .restored)
        #expect(returned.steps.contains(.returnToAccessPoint(Self.peripheral)))

        let declined = FakeLunaStationPort()
        let refusal = FakeLunaStationPort.failure(.notApproved, "return.not-authorized")
        declined.returns = [.failed(refusal)]
        #expect(
            await Self.commissioner(declined).restoreAccessPoint(record)
                == .deferred(refusal.message))

        let time = ManualHostClock()
        let away = FakeLunaStationPort()
        let unreachable = FakeLunaStationPort.failure(.notFound, "return.not-reachable")
        away.returns = Array(repeating: .deferred(unreachable), count: 3)
        let pending = Task {
            await Self.commissioner(away, clock: time.clock).restoreAccessPoint(record)
        }
        for _ in 1..<LunaStationCommissioner.returnAttempts {
            try? await time.waitForSleeps(1)
            time.advance(by: LunaStationCommissioner.returnInterval)
        }
        #expect(await pending.value == .deferred(unreachable.message))
        #expect(away.steps.filter { $0 == .returnToAccessPoint(Self.peripheral) }.count == 3)
    }

    @Test func aCancelledReturnStaysJournaled() async {
        let gate = FakeGate()
        let port = FakeLunaStationPort()
        port.during = { step in if case .returnToAccessPoint = step { await gate.wait() } }
        let record = LunaMultiview.record(Self.sighting)
        let commissioner = Self.commissioner(port)
        let pending = Task { await commissioner.restoreAccessPoint(record) }
        while !port.steps.contains(.returnToAccessPoint(Self.peripheral)) { await Task.yield() }
        pending.cancel()
        gate.open()
        #expect(await pending.value == .failed)
    }

    @Test func theScannerReportsEverySighting() async {
        let (stream, continuation) = AsyncStream.makeStream(of: [NearbyCamera].self)
        let scanner = LunaNearbyScanner(discover: { stream })
        var other = Self.sighting
        other.id = UUID().uuidString
        continuation.yield([Self.sighting, other])
        continuation.finish()
        var seen: [String] = []
        #expect(await scanner.waitUntilReady())
        await scanner.scan { seen.append($0.id) }
        #expect(seen == [Self.sighting.id, other.id])
    }
}

private struct CameraNotFound: Error {}
