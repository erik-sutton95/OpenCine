import Foundation
import OpenCineCore
import OpenCineCoreTestSupport
import Testing

@testable import OpenCineNikon

/// Shared Multiview (Plan 6): the Nikon Add list, its scanner and the member link the shared
/// coordinator drives. Scripted bodies and a manual clock; physical Nikon behavior is untested.
/// Kotlin mirror: `NikonMultiviewLinkTest`, same method names.
@Suite struct NikonMultiviewLinkTests {
    struct Down: Error {}

    // MARK: Add list and scanner

    @Test func theAddListMergesSightingsAndSavedSetupsByHost() {
        let sightings = [
            DiscoveredCamera(ip: "192.168.1.20", name: "Z 8", source: .bonjour),
            DiscoveredCamera(ip: "192.168.1.21", source: .liveness),
            DiscoveredCamera(ip: "192.168.1.22", source: .heldByAnotherDevice, heldByDeviceName: "iPad"),
            DiscoveredCamera(ip: "usb:7", name: "Z 6III", source: .usb),
        ]
        let saved = [
            NikonMultiviewSavedSetup(host: " 192.168.1.21 ", name: "ZR studio"),
            NikonMultiviewSavedSetup(host: "192.168.1.23", name: "Z f"),
            NikonMultiviewSavedSetup(host: "ap:Z_123", name: "Access point"),
            NikonMultiviewSavedSetup(host: "usb:7", name: "Cable"),
        ]
        let list = NikonMultiview.addList(
            sightings: sightings, saved: saved, excludedHosts: ["192.168.1.20 "])
        #expect(list.map(\.host) == ["192.168.1.21", "192.168.1.22", "192.168.1.23"], "a member's host is never listed")
        #expect(list.map(\.name) == ["ZR studio", "Camera 192.168.1.22", "Z f"], "a saved setup names its host's row")
        #expect(list[1].heldByAnotherDevice && list[1].holder == "iPad")
        let policy = NikonMultiview.policy
        #expect(!policy.discoversByProbe, "bodies are never probed")
        #expect(policy.qualification(list[0], experimental: false) == .qualified)
        #expect(policy.qualification(list[1], experimental: false) == .refused(.notReachable))
        #expect(policy.hostKey(" 192.168.1.21") == "192.168.1.21")
        #expect(list[0].id == NikonMultiviewCamera(host: "192.168.1.21 ", name: "Other").id, "one id per host")
        #expect(list[0].id != list[2].id)
    }

    @MainActor @Test func theScannerReportsEachPassAndNeverAsksAMembersHost() async throws {
        let clock = ManualHostClock()
        let asked = Recorder<([String], Set<String>)>()
        let scanner = NikonMultiviewScanner(
            sightings: { saved, excluded in
                asked.append((saved, excluded))
                // Another phone holds the body at .22 on the first pass and releases it.
                let released = asked.values.count > 1
                return [
                    DiscoveredCamera(ip: "192.168.1.20", name: "Z 8", source: .bonjour),
                    released
                        ? DiscoveredCamera(ip: "192.168.1.22", name: "Z 6III", source: .bonjour)
                        : DiscoveredCamera(
                            ip: "192.168.1.22", source: .heldByAnotherDevice, heldByDeviceName: "iPad"),
                ]
            },
            saved: {
                [
                    NikonMultiviewSavedSetup(host: "192.168.1.21", name: "ZR"),
                    NikonMultiviewSavedSetup(host: "192.168.1.23", name: "Member"),
                ]
            },
            excludedHosts: { ["192.168.1.23"] }, sleep: clock.clock.sleep)
        #expect(await scanner.waitUntilReady())
        let found = Recorder<String>()
        let scan = Task { await scanner.scan { found.append($0.host) } }
        try await clock.waitForSleeps(1)
        #expect(asked.values.first?.0 == ["192.168.1.21"], "a member's saved host is not dialled for liveness")
        #expect(asked.values.first?.1 == ["192.168.1.23"])
        clock.advance(by: .seconds(3))
        try await clock.waitForSleeps(1)
        #expect(
            found.values == ["192.168.1.20", "192.168.1.21", "192.168.1.20", "192.168.1.22", "192.168.1.21"],
            "a held body is not offered; once released it is")
        scanner.stop()
        clock.advance(by: .seconds(3))
        await scan.value
        #expect(asked.values.count == 2, "no pass after stop")
    }

    // MARK: Member link

    /// One scripted Z body on its own PTP session.
    final class Body: NikonMultiviewTransport, @unchecked Sendable {
        // SAFETY: all state behind `lock`.
        let serialNumber: String
        let commandOwner: NikonCommandOwner? = NikonCommandOwner()
        private let lock = NSLock()
        private var _log: [String] = []
        private var pending: [Result<PTPLiveViewFrame, Error>] = []
        private var waiter: CheckedContinuation<Result<PTPLiveViewFrame, Error>, Never>?
        private var _startFails = false
        var properties: [PTPPropertyCode: Data] = [:]

        init(serial: String) { serialNumber = serial }

        var log: [String] { lock.withLock { _log } }
        var startFails: Bool {
            get { lock.withLock { _startFails } }
            set { lock.withLock { _startFails = newValue } }
        }
        private func note(_ line: String) { lock.withLock { _log.append(line) } }

        /// The next frame the body sends.
        func frame(recording: Bool = false) {
            deliver(.success(PTPLiveViewFrame(
                jpeg: Data([0xFF, 0xD8]), timecode: Timecode(on: true, hour: 1, minute: 2, second: 3, frame: 4),
                isRecording: recording)))
        }

        /// The next frame request times out.
        func miss() { deliver(.failure(Down())) }

        /// The next frame request finds the socket closed (the transport closes it at a frame
        /// deadline, or the body hung up).
        func lose() { deliver(.failure(NativeCameraSessionError.connectionClosed)) }

        private func deliver(_ result: Result<PTPLiveViewFrame, Error>) {
            let waiting = lock.withLock { () -> CheckedContinuation<Result<PTPLiveViewFrame, Error>, Never>? in
                guard let waiter else {
                    pending.append(result)
                    return nil
                }
                self.waiter = nil
                return waiter
            }
            waiting?.resume(returning: result)
        }

        func liveViewFrame(deadline: Duration?) async throws -> PTPLiveViewFrame {
            let result = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Result<PTPLiveViewFrame, Error>, Never>) in
                    let ready = lock.withLock { () -> Result<PTPLiveViewFrame, Error>? in
                        if !pending.isEmpty { return pending.removeFirst() }
                        waiter = continuation
                        return nil
                    }
                    if let ready { continuation.resume(returning: ready) }
                }
            } onCancel: {
                let waiting = lock.withLock { () -> CheckedContinuation<Result<PTPLiveViewFrame, Error>, Never>? in
                    defer { waiter = nil }
                    return waiter
                }
                waiting?.resume(returning: .failure(CancellationError()))
            }
            return try result.get()
        }

        func configureMemberLiveView() async {}
        func startLiveView() async throws {
            note("startLiveView")
            if startFails { throw Down() }
        }
        func stopLiveView() async { note("stopLiveView") }
        func shutdown() async {
            commandOwner?.retire()
            note("shutdown")
        }
        func readStorageInfo() async throws -> PTPStorageInfo? { nil }
        func readCameraProperty(_ property: PTPPropertyCode) async throws -> Data {
            guard let data = lock.withLock({ properties[property] }) else { throw Down() }
            return data
        }
        func writeCameraProperty(_ write: PTPCameraPropertyWrite) async throws {
            note("write \(write.property)")
        }
        func startRecording() async throws { note("record start") }
        func stopRecording() async throws { note("record stop") }
    }

    /// The bodies on the network, the devices holding some, every dial, and a stage's opener and
    /// links on one manual clock.
    @MainActor final class Rig {
        let clock = ManualHostClock()
        var bodies: [String: Body] = [:]
        var holders: [String: String] = [:]
        /// What a dial of a host throws (a body that does not know this phone, say).
        var dialErrors: [String: Error] = [:]
        var connects: [String] = []
        var connectGate: FakeGate?
        var statuses: [MultiviewLinkStatus] = []
        var frames = 0
        private(set) lazy var opener = NikonMemberOpener<Body>(
            now: clock.clock.now, sleep: clock.clock.sleep,
            currentHolder: { [weak self] host in await self?.holders[host] },
            connect: { [weak self] host in
                guard let self else { throw Down() }
                return try await self.connect(host)
            },
            serialNumber: { $0.serialNumber }, close: { await $0.shutdown() })

        private func connect(_ host: String) async throws -> Body {
            connects.append(host)
            if let connectGate { await connectGate.wait() }
            if let error = dialErrors[host] { throw error }
            guard let body = bodies[host] else { throw Down() }
            return body
        }

        func link() -> NikonMultiviewLink<Body> {
            let link = NikonMultiviewLink(
                opener: opener, conversion: { $0 == .nLog ? "N-Log look" : nil },
                isCameraRefusal: { _ in false }, clock: clock.clock, framePace: { .zero },
                pollInterval: .seconds(5))
            link.onStatus = { [weak self] in self?.statuses.append($0) }
            link.onFrame = { [weak self] _ in self?.frames += 1 }
            return link
        }

        /// A link live on the body at 192.168.1.20 (serial 3001), one frame shown.
        func live(_ body: Body = Body(serial: "3001")) async throws -> NikonMultiviewLink<Body> {
            bodies["192.168.1.20"] = body
            let link = link()
            let camera = NikonMultiviewCamera(host: "192.168.1.20", name: "ZR")
            _ = try await link.open(camera, at: "192.168.1.20", expecting: nil, on: Self.network)
            try await link.startPreview(camera)
            body.frame()
            await until { link.pictureHealth == .live }
            return link
        }

        /// Three frame deadlines pass without a picture: the pump stops on a stall.
        func stall(_ link: NikonMultiviewLink<Body>, _ body: Body) async throws {
            for miss in 0..<NikonMemberRepair.missedFramesForStall {
                body.miss()
                if miss < NikonMemberRepair.missedFramesForStall - 1 {
                    try await clock.waitForSleeps(1)
                    clock.advance(by: .milliseconds(250))
                }
            }
            await until { link.pictureHealth == .stalled }
        }

        static let network = StationNetwork(ssid: "", password: "", hotspot: false)
    }

    /// A repair context that counts the attempts it grants.
    @MainActor final class Budget {
        var limit: Int
        var asked = 0
        init(_ limit: Int) { self.limit = limit }
        var context: MultiviewRepairContext {
            MultiviewRepairContext(beginAttempt: { [self] in
                asked += 1
                return asked <= limit
            })
        }
    }

    @MainActor @Test func openingChecksTheBodyAndRefusesWithOperatorCopy() async throws {
        let rig = Rig()
        rig.bodies["192.168.1.20"] = Body(serial: " 3001 ")
        rig.holders["192.168.1.21"] = "iPad"
        let link = rig.link()
        let camera = NikonMultiviewCamera(host: "192.168.1.20", name: "ZR")
        let proven = try await link.open(camera, at: "192.168.1.20", expecting: nil, on: Rig.network)
        #expect(proven == Array("3001".utf8), "the serial GetDeviceInfo reported is the identity")
        #expect(rig.statuses == [.opening])
        #expect(link.snapshot.device == .durable("3001", integration: NikonCameraSession.integration))

        let reopened = Task {
            try await link.open(camera, at: "192.168.1.20", expecting: Array("9999".utf8), on: Rig.network)
        }
        try await rig.clock.waitForSleeps(1)  // the host's settle after the close
        #expect(rig.connects.count == 1, "no Init inside the settle")
        rig.clock.advance(by: .milliseconds(1_200))
        await #expect(throws: NikonMultiviewLinkError.refused(.differentBody, heldBy: nil)) {
            try await reopened.value
        }

        let held = NikonMultiviewCamera(host: "192.168.1.21", name: "Z 8")
        do {
            _ = try await link.open(held, at: "192.168.1.21", expecting: nil, on: Rig.network)
            Issue.record("a held body opened")
        } catch let error as NikonMultiviewLinkError {
            #expect(error.errorDescription == "In use on iPad. Release it there, then tap Reconnect.")
        }
        #expect(!rig.connects.contains("192.168.1.21"), "a body another device holds is never dialled")
        #expect(await link.probe("192.168.1.22", on: Rig.network) == false)

        rig.dialErrors["192.168.1.24"] = NativeCameraSessionError.savedProfileRequired
        let unpaired = NikonMultiviewCamera(host: "192.168.1.24", name: "Z f")
        await #expect(throws: NikonMultiviewLinkError.notPaired) {
            try await link.open(unpaired, at: "192.168.1.24", expecting: nil, on: Rig.network)
        }
        #expect(
            NikonMultiviewLinkError.notPaired.operatorMessage
                == "This camera is not paired with this phone. Pair it in Your cameras, then tap Reconnect.")
        #expect(
            NikonMultiviewLinkError.connectFailure(NativeCameraSessionError.initFailed(.busy))
                == .refused(.heldByAnotherDevice, heldBy: nil))
        #expect(NikonMultiviewLinkError.connectFailure(Down()) == nil, "a silent dial is not found")
    }

    @MainActor @Test func thePumpPublishesFramesRecordStateAndTheToneLUT() async throws {
        let rig = Rig()
        let body = Body(serial: "3001")
        body.properties = [
            .batteryLevel: Data([80]), .movieFileType: Data(ByteCoding.uint32LE(0x0001_0A00)),
            .movieH265ToneMode: Data([1]),
        ]
        let link = try await rig.live(body)
        #expect(rig.statuses == [.opening, .controlling, .awaitingPicture, .live])
        #expect(rig.frames == 1)
        #expect(link.recordReport?.recording == false)
        #expect(link.timecode == Timecode(on: true, hour: 1, minute: 2, second: 3, frame: 4))
        body.frame()
        await until { link.recordingTone != nil }
        #expect(link.autoLUT == MultiviewAutoLUT(colorMode: "N-Log", conversion: "N-Log look"))
        #expect(link.reported.batteryPercent == 80)
        body.frame(recording: true)
        await until { link.recordReport?.recording == true }
        #expect(link.snapshot.recording.value == .recording)
        link.close()
    }

    @MainActor @Test func queuedWritesAndRecordGoOutOnlyAtTheSafePoint() async throws {
        let rig = Rig()
        let body = Body(serial: "3001")
        let link = try await rig.live(body)
        body.frame()
        await until { rig.frames == 2 }
        let receipt = (link.session as? NikonCameraSession)?.request(.startRecording)
        #expect(receipt?.isFinished == false)
        #expect(!body.log.contains("record start"), "the pump is waiting for a frame, not at its safe point")
        body.frame()
        await until { body.log.contains("record start") }
        link.close()
    }

    @MainActor @Test func threeMissedFramesRestartLiveViewInPlace() async throws {
        let rig = Rig()
        let body = Body(serial: "3001")
        let link = try await rig.live(body)
        try await rig.stall(link, body)
        #expect(rig.statuses.last == .reconnecting)
        let budget = Budget(2)
        guard case .repair(let work) = link.repair(budget.context) else {
            Issue.record("a stall repairs")
            return
        }
        #expect(await work() == .done)
        #expect(budget.asked == 1, "one attempt from the coordinator's budget")
        #expect(body.log.filter { $0 == "startLiveView" }.count == 2)
        #expect(rig.connects.count == 1, "restarted in place: no Init")
        body.frame()
        await until { link.pictureHealth == .live }
        guard case .healthy = link.repair(budget.context) else {
            Issue.record("a picture ends the episode")
            return
        }
        link.close()
    }

    @MainActor @Test func aRestartWithoutANewFrameReopens() async throws {
        let rig = Rig()
        let body = Body(serial: "3001")
        let link = try await rig.live(body)
        let recordedAt = link.recordReport?.receivedAt
        try await rig.stall(link, body)
        let budget = Budget(2)
        guard case .repair(let restart) = link.repair(budget.context) else {
            Issue.record("a stall repairs")
            return
        }
        #expect(await restart() == .done)
        #expect(link.pictureHealth != .live, "a restart is not a picture")
        let before = rig.statuses.count
        try await rig.stall(link, body)
        await until { rig.statuses.count > before && rig.statuses.last == .reconnecting }
        #expect(link.recordReport?.receivedAt == recordedAt, "no fresh record state without a frame")
        guard case .handled = link.repair(budget.context) else {
            Issue.record("the ladder waits out the settle")
            return
        }
        rig.clock.advance(by: .milliseconds(1_200))
        guard case .repair(let reopen) = link.repair(budget.context) else {
            Issue.record("the ladder escalates to a reopen")
            return
        }
        let reopening = Task { await reopen() }
        try await rig.clock.waitForSleeps(1)  // the opener's settle after it closed the old link
        rig.clock.advance(by: .milliseconds(1_200))
        #expect(await reopening.value == .done)
        #expect(rig.connects.count == 2, "a reopen is a new Init")
        #expect(budget.asked == 2)
        body.frame()
        await until { link.pictureHealth == .live }
        link.close()
    }

    @MainActor @Test func aDeadLinkReopensWithoutARestart() async throws {
        let rig = Rig()
        let body = Body(serial: "3001")
        let link = try await rig.live(body)
        body.lose()
        await until { link.pictureHealth == .stalled }
        #expect(rig.statuses.last == .reconnecting)
        await until { body.log.contains("shutdown") }
        #expect(link.transport == nil, "the dead link is closed through the opener")
        let budget = Budget(2)
        guard case .handled = link.repair(budget.context) else {
            Issue.record("the ladder waits out the settle")
            return
        }
        rig.clock.advance(by: .milliseconds(1_200))
        guard case .repair(let reopen) = link.repair(budget.context) else {
            Issue.record("a dead link reopens, no restart on its socket")
            return
        }
        #expect(await reopen() == .done)
        #expect(rig.connects.count == 2)
        #expect(budget.asked == 1, "both of the budget's attempts stay for reopens")
        #expect(body.log.filter { $0 == "startLiveView" }.count == 2)
        body.frame()
        await until { link.pictureHealth == .live }
        link.close()
    }

    @MainActor @Test func aLostLinkReopensTheSameBodyAfterTheSettle() async throws {
        let rig = Rig()
        let body = Body(serial: "3001")
        let link = try await rig.live(body)
        let first = link.session.id
        _ = link.lend()
        link.reclaim(nil)  // Live View lost the session
        await until { body.log.contains("shutdown") }  // closed through the opener: its settle
        let budget = Budget(2)
        guard case .handled = link.repair(budget.context) else {
            Issue.record("the ladder waits out the settle")
            return
        }
        #expect(budget.asked == 0, "a wait spends nothing")
        rig.clock.advance(by: .milliseconds(1_200))
        guard case .repair(let work) = link.repair(budget.context) else {
            Issue.record("a lost link reopens")
            return
        }
        let reopening = Task { await work() }
        await until { rig.connects.count == 2 }
        #expect(await reopening.value == .done)
        #expect(link.session.id != first, "a reopened link is a new session")
        #expect(link.host == "192.168.1.20")
        body.frame()
        await until { link.pictureHealth == .live }

        rig.bodies["192.168.1.20"] = Body(serial: "4002")
        _ = link.lend()
        link.reclaim(nil)
        await until { body.log.filter { $0 == "shutdown" }.count == 2 }
        rig.clock.advance(by: .milliseconds(1_200))
        guard case .repair(let other) = link.repair(budget.context) else {
            Issue.record("a lost link reopens")
            return
        }
        #expect(await other() == .done)
        #expect(link.transport == nil, "another body at the address is refused")
        link.close()
    }

    @MainActor @Test func aSpentBudgetOrATakeOverWaitsForTheOperator() async throws {
        let rig = Rig()
        let body = Body(serial: "3001")
        let link = try await rig.live(body)
        try await rig.stall(link, body)
        #expect(verdict(link.repair(Budget(0).context)) == NikonMultiviewCopy.couldNotRestore)

        let held = Body(serial: "3002")
        let taken = try await rig.live(held)
        _ = taken.lend()
        taken.reclaim(nil)
        await until { held.log.contains("shutdown") }
        rig.holders["192.168.1.20"] = "iPad"
        rig.clock.advance(by: .milliseconds(1_200))
        let budget = Budget(3)
        guard case .repair(let work) = taken.repair(budget.context) else {
            Issue.record("a lost link reopens")
            return
        }
        #expect(await work() == .done)
        #expect(
            verdict(taken.repair(budget.context)) == "In use on iPad. Release it there, then tap Reconnect.")
        #expect(budget.asked == 1, "a take-over spends no further attempt")
    }

    @MainActor @Test func aReopenThatReturnsAfterTheRepairWasGivenUpIsClosed() async throws {
        let rig = Rig()
        let body = Body(serial: "3001")
        let link = try await rig.live(body)
        _ = link.lend()
        link.reclaim(nil)
        await until { body.log.contains("shutdown") }
        rig.clock.advance(by: .milliseconds(1_200))
        let gate = FakeGate()
        rig.connectGate = gate
        guard case .repair(let work) = link.repair(Budget(2).context) else {
            Issue.record("a lost link reopens")
            return
        }
        let repair = Task { await work() }
        await until { gate.waiting == 1 }
        repair.cancel()  // the coordinator's repair deadline gave up on it
        gate.open()
        _ = await repair.value
        await until { body.log.filter { $0 == "shutdown" }.count == 2 }
        #expect(link.transport == nil, "the late link is not attached")
    }

    @MainActor @Test func closeEndsTheSessionWithoutARecordCommandAndTheNextOpenWaitsForIt() async throws {
        let rig = Rig()
        let body = Body(serial: "3001")
        let link = try await rig.live(body)
        link.close()
        #expect(link.recordReport == nil)
        await until { body.log.contains("shutdown") }
        #expect(!body.log.contains { $0.hasPrefix("record") }, "closing never stops a recording")
        #expect(body.log.suffix(2) == ["stopLiveView", "shutdown"])
        let camera = NikonMultiviewCamera(host: "192.168.1.20", name: "ZR")
        let again = Task { try await link.open(camera, at: "192.168.1.20", expecting: nil, on: Rig.network) }
        try await rig.clock.waitForSleeps(1)
        #expect(rig.connects.count == 1, "the settle after the close comes first")
        rig.clock.advance(by: .milliseconds(1_200))
        _ = try await again.value
        #expect(rig.connects.count == 2)
        link.close()
    }

    @MainActor @Test func theLiveViewLoanStopsThePumpAndAReplacementIsANewSession() async throws {
        let rig = Rig()
        let body = Body(serial: "3001")
        let link = try await rig.live(body)
        let first = link.session.id
        #expect(link.lend() === body)
        #expect(link.lend() == nil, "one loan at a time")
        #expect(verdict(link.repair(Budget(2).context)) == "healthy", "Live View owns the link meanwhile")
        link.reclaim(body)
        await until { body.log.filter { $0 == "startLiveView" }.count == 2 }
        #expect(link.session.id == first, "the same session comes back")
        body.frame()
        await until { rig.frames == 2 }

        let replacement = Body(serial: "3001")
        _ = link.lend()
        link.reclaim(replacement)
        #expect(link.session.id != first, "a replacement from Live View is a new session")
        await until { replacement.log.contains("startLiveView") }
        link.close()
    }
}

/// Values a `@Sendable` closure records for the test to read.
final class Recorder<Value>: @unchecked Sendable {
    // SAFETY: all state behind `lock`.
    private let lock = NSLock()
    private var stored: [Value] = []
    var values: [Value] { lock.withLock { stored } }
    func append(_ value: Value) { lock.withLock { stored.append(value) } }
}

/// A repair verdict as text: its case, or the operator copy it waits with.
private func verdict(_ step: MultiviewRepairStep) -> String {
    switch step {
    case .healthy: "healthy"
    case .handled: "handled"
    case .repair: "repair"
    case .waitForOperator(let message): message
    }
}

@MainActor private func until(
    _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
) async {
    for _ in 0..<20_000 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("condition never held", sourceLocation: sourceLocation)
}
