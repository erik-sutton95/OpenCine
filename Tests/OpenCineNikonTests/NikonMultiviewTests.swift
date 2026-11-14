import Foundation
import OpenCineCore
import Testing

@testable import OpenCineNikon

/// Shared Multiview prep (Plan 6): the Nikon operations a Pocket-standard Multiview tile needs.
/// Scripted links and a manual clock; physical Nikon behavior is untested. Kotlin mirror:
/// `NikonMultiviewTest`, same method names.
@Suite struct NikonMultiviewTests {
    struct LinkDown: Error {}

    /// One opened PTP link: which host it reached and the serial GetDeviceInfo reported.
    struct Link: Sendable, Equatable {
        let host: String
        let serial: String?
    }

    /// The bodies on the network, every dial and close, and a manual clock that `sleep` advances.
    final class Network: @unchecked Sendable {
        // SAFETY: all state behind `lock`.
        private let lock = NSLock()
        private var _connects: [String] = []
        private var _closed: [String] = []
        private var _sleeps: [Duration] = []
        private var _now = MonotonicInstant.zero
        private var _holderAsks: [String] = []
        var serials: [String: String?] = [:]
        /// Camera host to the device a fresh presence sweep finds serving it.
        var holders: [String: String] = [:]

        var connects: [String] { lock.withLock { _connects } }
        var closed: [String] { lock.withLock { _closed } }
        var sleeps: [Duration] { lock.withLock { _sleeps } }
        var now: MonotonicInstant { lock.withLock { _now } }
        var holderAsks: [String] { lock.withLock { _holderAsks } }

        func advance(_ duration: Duration) { lock.withLock { _now = _now + duration } }

        func sleep(_ duration: Duration) {
            lock.withLock {
                _sleeps.append(duration)
                _now = _now + duration
            }
        }

        func connect(_ host: String) throws -> Link {
            lock.withLock { _connects.append(host) }
            guard let serial = serials[host] else { throw LinkDown() }
            return Link(host: host, serial: serial)
        }

        func close(_ link: Link) { lock.withLock { _closed.append(link.host) } }

        func holder(of host: String) -> String? {
            lock.withLock {
                _holderAsks.append(host)
                return holders[host]
            }
        }
    }

    /// A point the first caller stops at until the test opens it (later callers pass straight
    /// through, so a regression fails instead of hanging), and tells the test it arrived.
    final class Gate: @unchecked Sendable {
        // SAFETY: all state behind `lock`.
        private let lock = NSLock()
        private var isOpen = false
        private var hasArrived = false
        private var passer: CheckedContinuation<Void, Never>?
        private var watchers: [CheckedContinuation<Void, Never>] = []

        /// The code under test: the first caller waits here until `open()`.
        func pass() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let (resume, arrived) = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
                    if hasArrived { return (true, []) }
                    hasArrived = true
                    let arrived = watchers
                    watchers = []
                    if isOpen { return (true, arrived) }
                    passer = continuation
                    return (false, arrived)
                }
                arrived.forEach { $0.resume() }
                if resume { continuation.resume() }
            }
        }

        /// The test: returns once the code under test waits at the gate.
        func arrival() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = lock.withLock { () -> Bool in
                    if hasArrived { return true }
                    watchers.append(continuation)
                    return false
                }
                if now { continuation.resume() }
            }
        }

        func open() {
            let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                isOpen = true
                defer { passer = nil }
                return passer
            }
            waiting?.resume()
        }
    }

    static let serial = "3001234"
    static let device = NikonMulticamPolicy.device(serialNumber: serial)!

    func opener(
        _ network: Network, connectGate: Gate? = nil, closeGate: Gate? = nil
    ) -> NikonMemberOpener<Link> {
        NikonMemberOpener(
            now: { network.now }, sleep: { network.sleep($0) },
            currentHolder: { network.holder(of: $0) },
            connect: { host in
                await connectGate?.pass()
                return try network.connect(host)
            },
            serialNumber: { $0.serial },
            close: { link in
                await closeGate?.pass()
                network.close(link)
            })
    }

    // MARK: Open a picked body

    @Test func openReturnsTheBodyAndItsSerialDevice() async throws {
        let network = Network()
        network.serials = ["192.168.1.30": Self.serial]
        let result = try await opener(network).open(host: "192.168.1.30", members: [], hostsInUse: [])
        #expect(result.link == Link(host: "192.168.1.30", serial: Self.serial))
        #expect(result.device == Self.device)
        #expect(network.connects == ["192.168.1.30"] && network.closed.isEmpty && network.sleeps.isEmpty)
    }

    /// A host a member or Live View holds is never dialled: a second Init drops its session.
    @Test func openRefusesAHostInUseWithoutDialling() async throws {
        let network = Network()
        network.serials = ["192.168.1.30": Self.serial]
        let result = try await opener(network).open(
            host: "192.168.1.30", members: [], hostsInUse: [" 192.168.1.30"])
        #expect(result.refusal == .hostInUse)
        #expect(network.connects.isEmpty)
    }

    @Test func openClosesAndRefusesABodyAlreadyInTheGroup() async throws {
        let network = Network()
        network.serials = ["192.168.1.40": Self.serial]  // the member, found again under a new address
        let result = try await opener(network).open(host: "192.168.1.40", members: [Self.device], hostsInUse: [])
        #expect(result.refusal == .alreadyMember)
        #expect(network.closed == ["192.168.1.40"])
    }

    @Test func openClosesAndRefusesADifferentBody() async throws {
        let network = Network()
        network.serials = ["192.168.1.30": "3009999"]
        let result = try await opener(network).open(
            host: "192.168.1.30", expectedSerial: Self.serial, members: [], hostsInUse: [])
        #expect(result.refusal == .differentBody)
        #expect(network.closed == ["192.168.1.30"])
    }

    /// Unknown is not a pass: without a serial the group cannot tell this body from a member.
    @Test func openClosesAndRefusesABodyWithoutASerial() async throws {
        let network = Network()
        network.serials = ["192.168.1.30": " "]
        let result = try await opener(network).open(host: "192.168.1.30", members: [], hostsInUse: [])
        #expect(result.refusal == .noIdentity)
        #expect(network.closed == ["192.168.1.30"])
    }

    /// The ZR can hold the PTP slot briefly after CloseSession; an Init inside that window is what
    /// tips a reconnect into a wedge. A failed dial counts as a release too. Other hosts never wait.
    @Test func openWaitsTheReconnectSettleAfterAClose() async throws {
        let network = Network()
        network.serials = ["192.168.1.30": Self.serial, "192.168.1.31": "3005678"]
        let opener = opener(network)
        let first = try #require(try await opener.open(host: "192.168.1.30", members: [], hostsInUse: []).link)
        await opener.close(first, host: "192.168.1.30")
        network.advance(.milliseconds(200))
        _ = try await opener.open(host: "192.168.1.31", members: [], hostsInUse: [])
        #expect(network.sleeps.isEmpty)
        _ = try await opener.open(host: "192.168.1.30", members: [], hostsInUse: [])
        #expect(network.sleeps == [.milliseconds(1_000)])

        // Nothing answers at .50: the dial fails.
        await #expect(throws: LinkDown.self) {
            try await opener.open(host: "192.168.1.50", members: [], hostsInUse: [])
        }
        _ = try? await opener.open(host: "192.168.1.50", members: [], hostsInUse: [])
        #expect(network.sleeps == [.milliseconds(1_000), NikonMemberTiming.reconnectSettle])
    }

    /// A body another phone holds hands its session to a new Init without refusing it (a ZR drops
    /// the phone holding it), and the list's held rows can be 30 s old: the opener asks now.
    @Test func openRefusesABodyAnotherDeviceHoldsWithoutDialling() async throws {
        let network = Network()
        network.serials = ["192.168.1.30": Self.serial]
        network.holders = ["192.168.1.30": "Phone B"]
        let result = try await opener(network).open(host: "192.168.1.30", members: [], hostsInUse: [])
        #expect(result.refusal == .heldByAnotherDevice && result.heldBy == "Phone B")
        #expect(network.holderAsks == ["192.168.1.30"] && network.connects.isEmpty)
    }

    /// A repair passes the group's own sets: the member's host is not in use against itself, and
    /// its serial is not "already in the group". Another member and another body are still refused.
    @Test func reopenOpensTheMembersOwnHostAndChecksItsSerial() async throws {
        let network = Network()
        let other = try #require(NikonMulticamPolicy.device(serialNumber: "3005678"))
        network.serials = ["192.168.1.30": Self.serial]
        let opener = opener(network)
        let members: Set<CameraDeviceID> = [Self.device, other]
        let hosts: Set<String> = [" 192.168.1.30", "192.168.1.31"]
        let result = try await opener.reopen(Self.device, host: "192.168.1.30", members: members, hostsInUse: hosts)
        #expect(result.link == Link(host: "192.168.1.30", serial: Self.serial) && result.device == Self.device)
        #expect(network.connects == ["192.168.1.30"] && network.closed.isEmpty)

        network.serials = ["192.168.1.30": "3005678"]
        let swapped = try await opener.reopen(Self.device, host: "192.168.1.30", members: members, hostsInUse: hosts)
        #expect(swapped.refusal == .alreadyMember, "another member answered at this host")
        network.serials = ["192.168.1.30": "3009999"]
        let stranger = try await opener.reopen(Self.device, host: "192.168.1.30", members: members, hostsInUse: hosts)
        #expect(stranger.refusal == .differentBody)
        #expect(network.closed == ["192.168.1.30", "192.168.1.30"])
    }

    /// A double tap, or an Add pick racing a repair of the same host, must not send two Inits to
    /// one body: the second Init drops the first session.
    @Test func openRefusesAHostWhileAnOpenOfItIsInFlight() async throws {
        let network = Network()
        network.serials = ["192.168.1.30": Self.serial]
        let gate = Gate()
        let opener = opener(network, connectGate: gate)
        let first = Task { try await opener.open(host: "192.168.1.30", members: [], hostsInUse: []) }
        await gate.arrival()
        let second = try await opener.open(host: "192.168.1.30 ", members: [], hostsInUse: [])
        let repair = try await opener.reopen(Self.device, host: "192.168.1.30", members: [Self.device], hostsInUse: [])
        #expect(second.refusal == .hostInUse && repair.refusal == .hostInUse)
        gate.open()
        #expect(try await first.value.device == Self.device)
        #expect(network.connects == ["192.168.1.30"])
        // Once that open is over, the host is free to open again (after its settle).
        _ = try await opener.open(host: "192.168.1.30", members: [Self.device], hostsInUse: [])
        #expect(network.connects == ["192.168.1.30", "192.168.1.30"])
    }

    /// Closing a refused body finishes even when the picker goes away mid-close: a half-closed
    /// session would hold the PTP slot, and the next open must still wait the settle.
    @Test func refusalCloseCompletesWhenTheOpenIsCancelled() async throws {
        let network = Network()
        network.serials = ["192.168.1.30": Self.serial]
        let gate = Gate()
        let opener = opener(network, closeGate: gate)
        let open = Task { try await opener.open(host: "192.168.1.30", members: [Self.device], hostsInUse: []) }
        await gate.arrival()
        open.cancel()
        gate.open()
        _ = try? await open.value
        #expect(network.closed == ["192.168.1.30"])
        _ = try await opener.open(host: "192.168.1.30", members: [], hostsInUse: [])
        #expect(network.sleeps == [NikonMemberTiming.reconnectSettle])
    }

    // MARK: Auto LUT source

    /// Packed `MovFileType` values (`0x00_CC_DD_KK`, little-endian on the wire).
    static func fileType(_ raw: UInt32) -> Data { Data(ByteCoding.uint32LE(raw)) }
    static let h265TenBit: UInt32 = 0x0001_0A00
    static let h265EightBit: UInt32 = 0x0001_0800
    static let proResHQ: UInt32 = 0x0010_0A00
    static let r3d: UInt32 = 0x0031_0C00

    /// Unknown is nil, never SDR: a tone property alone does not say which codec records.
    @Test func recordingToneIsUnknownUntilTheCodecReads() {
        var tone = NikonRecordingTone()
        tone.apply(.movieH265ToneMode, data: Data([1]))
        #expect(tone.tone == nil && tone.transfer == nil)
        tone.apply(.movieFileType, data: Self.fileType(Self.h265TenBit))
        #expect(tone.tone == .nLog && tone.transfer == .nlog)
        tone.apply(.movieH265ToneMode, data: Data([7]))
        #expect(tone.tone == nil, "a value the body has not named")
        tone.apply(.movieH265ToneMode, data: Data([1]))
        tone.apply(.movieFileType, data: Data([0x00]))
        #expect(tone.tone == nil, "a malformed codec read")
    }

    @Test func recordingToneFollowsTheCodecsToneProperty() {
        var tone = NikonRecordingTone()
        tone.apply(.movieH265ToneMode, data: Data([0]))
        tone.apply(.movieProResToneMode, data: Data([2]))
        tone.apply(.movieFileType, data: Self.fileType(Self.proResHQ))
        #expect(tone.tone == .hlg && tone.transfer == .hdr)
        tone.apply(.movieFileType, data: Self.fileType(Self.h265TenBit))
        #expect(tone.tone == .sdr && tone.transfer == .rec709)
    }

    @Test func fixedToneCodecsNeedNoToneRead() {
        var tone = NikonRecordingTone()
        tone.apply(.movieFileType, data: Self.fileType(Self.r3d))
        #expect(tone.tone == .log3G10 && tone.transfer == .log3G10)
        tone.apply(.movieH265ToneMode, data: Data([1]))
        tone.apply(.movieFileType, data: Self.fileType(Self.h265EightBit))
        #expect(tone.tone == .sdr, "8-bit H.265 records SDR whatever 0x1D001 holds")
    }

    /// One scripted body for the member poll: what it reports and every read it answered.
    final class ToneBody: NikonControlTransport, @unchecked Sendable {
        // SAFETY: all state behind `lock`.
        private let lock = NSLock()
        private var _reads: [PTPPropertyCode] = []
        var properties: [PTPPropertyCode: Data] = [:]
        var readFails = false

        var reads: [PTPPropertyCode] { lock.withLock { _reads } }

        func readCameraProperty(_ property: PTPPropertyCode) async throws -> Data {
            lock.withLock { _reads.append(property) }
            if readFails { throw LinkDown() }
            guard let data = lock.withLock({ properties[property] }) else { throw LinkDown() }
            return data
        }

        func writeCameraProperty(_ write: PTPCameraPropertyWrite) async throws { throw LinkDown() }
        func startRecording() async throws { throw LinkDown() }
        func stopRecording() async throws { throw LinkDown() }
    }

    /// The member poll reads the codec, then only that codec's tone property (none for a fixed
    /// tone). A read that fails keeps the last value: telemetry is never invented or dropped.
    @MainActor @Test func pollRecordingToneReadsTheCodecThenItsToneOnly() async {
        let body = ToneBody()
        body.properties = [.movieFileType: Self.fileType(Self.h265TenBit), .movieH265ToneMode: Data([1])]
        let control = NikonMemberControl(serialNumber: Self.serial, isCameraRefusal: { _ in false })
        #expect(control.recordingTone.tone == nil)
        #expect(await control.pollRecordingTone(on: body) == .nLog)
        #expect(body.reads == [.movieFileType, .movieH265ToneMode])
        #expect(control.recordingTone.transfer == .nlog)

        body.properties[.movieFileType] = Self.fileType(Self.r3d)
        #expect(await control.pollRecordingTone(on: body) == .log3G10)
        #expect(body.reads.suffix(1) == [.movieFileType])

        body.readFails = true
        #expect(await control.pollRecordingTone(on: body) == .log3G10)

        control.lend()
        let before = body.reads.count
        _ = await control.pollRecordingTone(on: body)
        #expect(body.reads.count == before, "a link lent to Live View is that view's to read")
    }

    // MARK: Bounded member repair

    static func at(_ milliseconds: Int) -> MonotonicInstant { .zero + .milliseconds(milliseconds) }

    /// A caller-owned budget of `limit` attempts, counting every ask.
    final class Budget {
        let limit: Int
        var asks = 0
        var used = 0
        init(limit: Int) { self.limit = limit }
        func begin() -> Bool {
            asks += 1
            guard used < limit else { return false }
            used += 1
            return true
        }
    }

    /// A stream that stops on a live link restarts live view in place first: no re-Init.
    @Test func repairRestartsLiveViewInPlaceForAStall() {
        var repair = NikonMemberRepair()
        let budget = Budget(limit: 3)
        repair.frameMissed(at: Self.at(0))
        repair.frameMissed(at: Self.at(0))
        #expect(repair.next(at: Self.at(0), beginAttempt: budget.begin) == .none)
        repair.frameMissed(at: Self.at(0))
        #expect(repair.next(at: Self.at(0), beginAttempt: budget.begin) == .restartLiveView)
        #expect(repair.next(at: Self.at(0), beginAttempt: budget.begin) == .none, "one attempt in flight")
        repair.attemptSucceeded()
        // Still no picture after the restart: the link is gone, so the next rung reopens it.
        for _ in 0..<3 { repair.frameMissed(at: Self.at(2_000)) }
        #expect(repair.next(at: Self.at(2_000), beginAttempt: budget.begin) == .wait(until: Self.at(3_200)))
        #expect(repair.next(at: Self.at(3_200), beginAttempt: budget.begin) == .reopen)
        #expect(budget.used == 2)
    }

    @Test func repairReopensOnlyAfterTheSettle() {
        var repair = NikonMemberRepair()
        let budget = Budget(limit: 3)
        repair.linkLost(at: Self.at(0))
        #expect(repair.next(at: Self.at(500), beginAttempt: budget.begin) == .wait(until: Self.at(1_200)))
        #expect(budget.asks == 0, "waiting costs no attempt")
        #expect(repair.next(at: Self.at(1_200), beginAttempt: budget.begin) == .reopen)
        #expect(budget.used == 1)
    }

    @Test func repairSpacesFailedReopens() {
        var repair = NikonMemberRepair()
        let budget = Budget(limit: 3)
        repair.linkLost(at: Self.at(0))
        #expect(repair.next(at: Self.at(1_200), beginAttempt: budget.begin) == .reopen)
        repair.attemptFailed(at: Self.at(3_000))
        #expect(repair.next(at: Self.at(3_000), beginAttempt: budget.begin) == .wait(until: Self.at(8_000)))
        #expect(repair.next(at: Self.at(8_000), beginAttempt: budget.begin) == .reopen)
    }

    /// The caller's budget (the coordinator's `RecoveryBudget`) decides every attempt; once it
    /// refuses, the tile waits for the operator's Reconnect and nothing asks again.
    @Test func repairAsksTheBudgetBeforeEveryAttempt() {
        var repair = NikonMemberRepair()
        let budget = Budget(limit: 2)
        repair.linkLost(at: Self.at(0))
        #expect(repair.next(at: Self.at(1_200), beginAttempt: budget.begin) == .reopen)
        repair.attemptFailed(at: Self.at(1_300))
        #expect(repair.next(at: Self.at(6_300), beginAttempt: budget.begin) == .reopen)
        repair.attemptFailed(at: Self.at(6_400))
        #expect(repair.next(at: Self.at(11_400), beginAttempt: budget.begin) == .waitForOperator(.budgetSpent))
        #expect(repair.next(at: Self.at(20_000), beginAttempt: budget.begin) == .waitForOperator(.budgetSpent))
        #expect(budget.asks == 3)
        repair.reset()
        #expect(repair.next(at: Self.at(20_000), beginAttempt: budget.begin) == .none)
    }

    /// Another phone took the body: reopening would take it straight back (two phones re-taking one
    /// session wedge a ZR), so the tile waits for the operator without spending an attempt.
    @Test func repairWaitsForTheOperatorAfterATakeOver() {
        var repair = NikonMemberRepair()
        let budget = Budget(limit: 3)
        repair.linkLost(at: Self.at(0))
        repair.takenOver()
        #expect(repair.next(at: Self.at(5_000), beginAttempt: budget.begin) == .waitForOperator(.takenOver))
        #expect(budget.asks == 0)
    }

    /// A picture ends the episode: a later stall starts at the first rung again.
    @Test func aFrameEndsTheEpisode() {
        var repair = NikonMemberRepair()
        let budget = Budget(limit: 5)
        repair.streamStalled(at: Self.at(0))
        #expect(repair.next(at: Self.at(0), beginAttempt: budget.begin) == .restartLiveView)
        repair.attemptSucceeded()
        repair.frameArrived()
        #expect(repair.next(at: Self.at(100), beginAttempt: budget.begin) == .none)
        repair.streamStalled(at: Self.at(9_000))
        #expect(repair.next(at: Self.at(9_000), beginAttempt: budget.begin) == .restartLiveView)
    }
}
