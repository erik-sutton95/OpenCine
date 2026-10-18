import Foundation
import OpenCineCore
import Testing

@testable import OpenCineNikon

@MainActor
@Suite("Nikon explicit queued command admission")
struct NikonCommandAdmissionTests {
    @Test func authorityCaptureSurvivesReadbackButNotSurrenderAndRegrant() {
        let link = AdmittedLink()
        var facts = NikonCameraSessionTests.movieFacts()
        let runtime = NikonMonitorRuntime(link: link, facts: facts)
        let captured = runtime.session.captureCommandAuthority()
        facts.recording = true
        runtime.updateFacts(facts)
        #expect(captured(), "Unrelated camera observations do not retire source authority")
        facts.holdsControl = false
        runtime.updateFacts(facts)
        facts.holdsControl = true
        runtime.updateFacts(facts)
        #expect(!captured(), "A held native job must not revive after authority returns")
        let current = runtime.session.captureCommandAuthority()
        #expect(current())
        runtime.session.close(.requested)
        #expect(!current())
    }

    @Test("A supplied source receipt never changes the existing direct command path")
    func sourceBoundAdmissionIsExplicitAndDirectOperationsRemainUnchanged() async throws {
        let link = AdmittedLink()
        let gate = ReceiptGate()
        let admission = NikonCommandAdmission(
            owner: try #require(link.commandOwner), isCurrent: { gate.isCurrent })
        let runtime = NikonMonitorRuntime(link: link, facts: NikonCameraSessionTests.movieFacts())
        let supplied = runtime.session.request(.set(.iso(.manual(1600))), admission: admission)
        #expect(supplied.stage == .admitted)
        #expect(await runtime.serviceControlSafePoint())
        #expect(runtime.session.receipt(of: supplied.operation)?.stage == .confirmed)
        #expect(runtime.session.refresh().value(of: .iso).value == .iso(.manual(1600)))

        gate.revoke()
        let refused = runtime.session.request(.set(.iso(.manual(3200))), admission: admission)
        #expect(refused.stage == .rejected(.authorityExpired))
        let direct = runtime.session.request(.set(.iso(.manual(3200))))
        #expect(direct.stage == .admitted)
        #expect(await runtime.serviceControlSafePoint())
        #expect(runtime.session.receipt(of: direct.operation)?.stage == .confirmed)
        #expect(link.writes.count == 2)
        #expect(
            link.writes.last?.data
                == PTPCameraPropertyWrite.isoWrite(label: "3200", dualBase: false)?.data)
    }

    @Test("Revoked queued record and setting operations send no command, including on close")
    func expiredQueuedRecordAndWriteNeverDispatch() async throws {
        let link = AdmittedLink()
        let gate = ReceiptGate()
        let admission = NikonCommandAdmission(
            owner: try #require(link.commandOwner), isCurrent: { gate.isCurrent })
        let runtime = NikonMonitorRuntime(
            link: link, ownsLink: false, facts: NikonCameraSessionTests.movieFacts())
        let record = runtime.session.request(.startRecording, admission: admission)
        let setting = runtime.session.request(
            .set(.whiteBalance(.kelvin(4000))), admission: admission)
        #expect(record.stage == .admitted)
        #expect(setting.stage == .admitted)
        gate.revoke()
        #expect(await runtime.serviceControlSafePoint())
        #expect(
            runtime.session.receipt(of: record.operation)?.stage == .rejected(.authorityExpired))
        #expect(await runtime.serviceControlSafePoint())
        #expect(
            runtime.session.receipt(of: setting.operation)?.stage == .rejected(.authorityExpired))
        #expect(!runtime.hasQueuedCommands)
        #expect(link.commands.isEmpty)
        runtime.session.close(.requested)
        #expect(link.commands.isEmpty)
        #expect(link.closes == 0)
    }

    @Test("A captured external holder survives local surrender without publishing local authority")
    func externalHolderAdmissionSurvivesLocalSurrenderWithoutPublishingOwner() async throws {
        let link = AdmittedLink()
        let admission = NikonCommandAdmission(
            owner: try #require(link.commandOwner), isCurrent: { true })
        var facts = NikonCameraSessionTests.movieFacts()
        let runtime = NikonMonitorRuntime(link: link, facts: facts)
        let supplied = runtime.session.request(.set(.iso(.manual(1600))), admission: admission)
        facts.holdsControl = false
        runtime.updateFacts(facts)
        #expect(runtime.hasQueuedCommands)
        #expect(runtime.session.refresh().authority == .unavailable(.authority))
        #expect(await runtime.serviceControlSafePoint())
        #expect(runtime.session.receipt(of: supplied.operation)?.stage == .confirmed)
        #expect(runtime.session.refresh().authority == .unavailable(.authority))
        let before = link.commands.count
        #expect(runtime.session.request(.set(.iso(.manual(3200)))).stage == .rejected(.noAuthority))
        #expect(link.commands.count == before)
        #expect(!runtime.hasQueuedCommands)

        let record = runtime.session.request(.startRecording, admission: admission)
        #expect(record.stage == .admitted)
        #expect(await runtime.serviceControlSafePoint())
        #expect(link.commands.last == "record-start")
        #expect(runtime.session.receipt(of: record.operation)?.stage == .awaitingObservation)
        facts.recording = true
        runtime.updateFacts(facts)
        #expect(runtime.session.receipt(of: record.operation)?.stage == .confirmed)
        #expect(runtime.session.refresh().authority == .unavailable(.authority))
    }

    @Test("An identically named replacement link cannot borrow an older link's receipt")
    func linkReplacementRefusesAnOlderSuppliedReceipt() async throws {
        let old = AdmittedLink()
        let admission = NikonCommandAdmission(
            owner: try #require(old.commandOwner), isCurrent: { true })
        let runtime = NikonMonitorRuntime(link: old, facts: NikonCameraSessionTests.movieFacts())
        let before = runtime.session.refresh()
        let pending = runtime.session.request(.set(.iso(.manual(1600))), admission: admission)
        let replacement = AdmittedLink()
        #expect(replacement.serialNumber == old.serialNumber)
        runtime.replaceLink(replacement)
        #expect(runtime.session.id == before.session)
        #expect(await runtime.serviceControlSafePoint())
        #expect(
            runtime.session.receipt(of: pending.operation)?.stage == .rejected(.authorityExpired))
        #expect(old.commands.isEmpty)
        #expect(replacement.commands.isEmpty)
        let direct = runtime.session.request(.set(.iso(.manual(3200))))
        #expect(await runtime.serviceControlSafePoint())
        #expect(runtime.session.receipt(of: direct.operation)?.stage == .confirmed)
        #expect(replacement.writes.count == 1)
    }

    @Test("A waiting native send rechecks its receipt; entered noncancellable work still completes")
    func queuedNativeBoundaryRechecksReceiptButEnteredWorkCompletes() async throws {
        for hold in [AdmittedLink.Hold.beforeDispatch, .afterDispatch] {
            let link = AdmittedLink()
            let gate = ReceiptGate()
            let admission = NikonCommandAdmission(
                owner: try #require(link.commandOwner), isCurrent: { gate.isCurrent })
            link.hold = hold
            let runtime = NikonMonitorRuntime(
                link: link, facts: NikonCameraSessionTests.movieFacts())
            let pending = runtime.session.request(.set(.iso(.manual(1600))), admission: admission)
            let service = Task { await runtime.serviceControlSafePoint() }
            await link.waitUntilHeld()
            #expect(link.writes.count == (hold == .beforeDispatch ? 0 : 1))
            gate.revoke()
            link.release()
            #expect(await service.value)
            let stage = runtime.session.receipt(of: pending.operation)?.stage
            #expect(stage == (hold == .beforeDispatch ? .rejected(.authorityExpired) : .confirmed))
            #expect(link.writes.count == (hold == .beforeDispatch ? 0 : 1))
            #expect(!runtime.hasQueuedCommands)
        }
    }

    @Test("Revocation between dependent writes preserves the already accepted part as unknown")
    func partialCompositeWriteStopsAfterAuthorityExpiresWithoutClaimingNoEffect() async throws {
        let link = AdmittedLink()
        let gate = ReceiptGate()
        let admission = NikonCommandAdmission(
            owner: try #require(link.commandOwner), isCurrent: { gate.isCurrent })
        let runtime = NikonMonitorRuntime(link: link, facts: NikonCameraSessionTests.movieFacts())
        let pending = runtime.session.request(
            .set(.whiteBalance(.kelvin(4000))), admission: admission)
        #expect(await runtime.serviceControlSafePoint())
        #expect(runtime.session.receipt(of: pending.operation)?.stage == .accepted)
        #expect(link.writes.count == 1)
        gate.revoke()
        #expect(await runtime.serviceControlSafePoint())
        #expect(runtime.session.receipt(of: pending.operation)?.stage == .outcomeUnknown)
        #expect(link.writes.count == 1)
        #expect(!runtime.hasQueuedCommands)
    }

    @Test("Member guarded writes retire at its queued safe point, while legacy writes still execute")
    func memberQueuedAdmissionIsExplicitAndLegacyWritesRemainUnchanged() async throws {
        let link = AdmittedLink()
        let gate = ReceiptGate()
        let admission = NikonCommandAdmission(owner: try #require(link.commandOwner), isCurrent: { gate.isCurrent })
        let member = NikonMemberControl(serialNumber: link.serialNumber,
            facts: NikonCameraSessionTests.movieFacts(), commandOwner: link.commandOwner,
            isCameraRefusal: NativeCameraSessionError.isCameraRefusal)
        let approved = member.session.request(.set(.iso(.manual(1600))), admission: admission)
        #expect(approved.stage == .admitted)
        gate.revoke()
        #expect(await member.service(link).isEmpty)
        #expect(member.session.receipt(of: approved.operation)?.stage == .rejected(.authorityExpired))
        #expect(link.commands.isEmpty)
        #expect(!member.hasQueuedCommands)
        let direct = member.session.request(.set(.iso(.manual(3200))))
        #expect(direct.stage == .admitted)
        _ = await member.service(link)
        #expect(member.session.receipt(of: direct.operation)?.stage == .confirmed)
        #expect(link.writes.count == 1)
        #expect(member.session.refresh().value(of: .iso).value == .iso(.manual(3200)))
    }

    @Test("Member guarded adapter fails closed when no established transport owner was supplied")
    func memberMissingAdapterAndWrongOwnerCannotQueueCommands() throws {
        let link = AdmittedLink()
        let admission = NikonCommandAdmission(owner: try #require(link.commandOwner), isCurrent: { true })
        let legacy = NikonMemberControl(serialNumber: link.serialNumber,
            facts: NikonCameraSessionTests.movieFacts(), isCameraRefusal: NativeCameraSessionError.isCameraRefusal)
        #expect(legacy.session.request(.set(.iso(.manual(1600))), admission: admission).stage == .rejected(.authorityExpired))
        #expect(!legacy.hasQueuedCommands)
        let member = NikonMemberControl(serialNumber: link.serialNumber,
            facts: NikonCameraSessionTests.movieFacts(), commandOwner: link.commandOwner,
            isCameraRefusal: NativeCameraSessionError.isCameraRefusal)
        let other = NikonCommandAdmission(owner: NikonCommandOwner(), isCurrent: { true })
        #expect(member.session.request(.set(.iso(.manual(1600))), admission: other).stage == .rejected(.authorityExpired))
        #expect(!member.hasQueuedCommands)
    }

    @Test("A member's held native queue refuses expired first sends and finishes entered readback")
    func memberHeldNativeDispatchKeepsOriginalOutcome() async throws {
        for hold in [AdmittedLink.Hold.beforeDispatch, .afterDispatch] {
            let link = AdmittedLink()
            let gate = ReceiptGate()
            let admission = NikonCommandAdmission(owner: try #require(link.commandOwner), isCurrent: { gate.isCurrent })
            let member = NikonMemberControl(serialNumber: link.serialNumber,
                facts: NikonCameraSessionTests.movieFacts(), commandOwner: link.commandOwner,
                isCameraRefusal: NativeCameraSessionError.isCameraRefusal)
            let approved = member.session.request(.set(.iso(.manual(1600))), admission: admission)
            #expect(approved.stage == .admitted)
            link.hold = hold
            let work = Task { await member.service(link) }
            await link.waitUntilHeld()
            #expect(link.writes.count == (hold == .beforeDispatch ? 0 : 1))
            gate.revoke()
            link.release()
            _ = await work.value
            #expect(link.writes.count == (hold == .beforeDispatch ? 0 : 1))
            #expect(member.session.receipt(of: approved.operation)?.stage ==
                (hold == .beforeDispatch ? .rejected(.authorityExpired) : .confirmed))
            #expect(!member.hasQueuedCommands)
        }
    }

    @Test("A member completes the first accepted part but never sends the successor after retirement")
    func memberMultipartWriteDoesNotBorrowRetiredEditor() async throws {
        let link = AdmittedLink()
        let gate = ReceiptGate()
        let admission = NikonCommandAdmission(owner: try #require(link.commandOwner), isCurrent: { gate.isCurrent })
        let member = NikonMemberControl(serialNumber: link.serialNumber,
            facts: NikonCameraSessionTests.movieFacts(), commandOwner: link.commandOwner,
            isCameraRefusal: NativeCameraSessionError.isCameraRefusal)
        let approved = member.session.request(.set(.whiteBalance(.kelvin(4000))), admission: admission)
        #expect(approved.stage == .admitted)
        link.hold = .afterDispatch
        let work = Task { await member.service(link) }
        await link.waitUntilHeld()
        #expect(link.writes.count == 1)
        gate.revoke()
        link.release()
        _ = await work.value
        #expect(link.writes.count == 1)
        #expect(member.session.receipt(of: approved.operation)?.stage == .outcomeUnknown)
        #expect(!member.hasQueuedCommands)
    }

    #if canImport(Darwin) && canImport(os)
        @Test(
            "Authority revoked behind the actual transaction gate cannot send first-request bytes")
        func expiredTransactionWaiterReleasesGateWithoutFirstSend() async throws {
            let serial = AsyncSerialGate()
            try await serial.wait()
            let receipt = ReceiptGate()
            let admission = NikonCommandAdmission(
                owner: NikonCommandOwner(), isCurrent: { receipt.isCurrent })
            let dispatch = FirstSendPort()
            let waiting = Task {
                try await serial.wait()
                defer { serial.signal() }
                do {
                    try admission.requireCurrent()
                    try admission.perform { dispatch.send() }
                    return false
                } catch NativeCameraSessionError.commandAuthorityExpired {
                    return true
                }
            }
            receipt.revoke()
            serial.signal()
            #expect(try await waiting.value)
            #expect(dispatch.sends == 0)
            try await serial.wait()
            dispatch.send()
            serial.signal()
            #expect(dispatch.sends == 1)
        }
    #endif
}

private final class ReceiptGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var isCurrent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }
    func revoke() {
        lock.lock()
        active = false
        lock.unlock()
    }
}

private final class FirstSendPort: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var sends: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    func send() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

/// Only native scheduling is controlled here. Production uses NativeCameraSession and its
/// transport gate/socket queue/ICC first-send checks; this does not claim SDK or camera evidence.
@MainActor
private final class AdmittedLink: NikonMonitorLink {
    enum Hold: Equatable { case beforeDispatch, afterDispatch }
    let serialNumber = "3000123"
    let commandOwner: NikonCommandOwner? = NikonCommandOwner()
    private(set) var commands: [String] = []
    private(set) var writes: [PTPCameraPropertyWrite] = []
    private(set) var closes = 0
    var hold: Hold?
    private var properties: [PTPPropertyCode: Data] = [:]
    private var held: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?

    func supportsProperty(_ property: PTPPropertyCode) -> Bool { true }
    func configureLiveView(size: UInt8, compression: UInt8) async {}
    func startLiveView() async throws {}
    func stopLiveView() async { commands.append("live-stop") }
    func liveViewFrame(deadline: Duration?) async throws -> PTPLiveViewFrame {
        throw NativeCameraSessionError.connectionClosed
    }
    func readLastCommandRoundTripMilliseconds() -> Double? { nil }
    func sendKeepAlive() async throws {}
    func nextEvent() async throws -> PTPEvent { throw NativeCameraSessionError.connectionClosed }
    func pollStillReleaseReadiness() async throws -> StillReleaseReadiness { .complete }
    func shutdown() async {
        closes += 1
        commandOwner?.retire()
    }
    func writeCameraProperty(_ write: PTPCameraPropertyWrite) async throws { send(write) }
    func writeCameraProperty(_ write: PTPCameraPropertyWrite, admission: NikonCommandAdmission)
        async throws
    {
        try admission.require(owner: commandOwner)
        if hold == .beforeDispatch { await suspend() }
        try admission.perform { send(write) }
        if hold == .afterDispatch { await suspend() }
    }
    func readCameraProperty(_ property: PTPPropertyCode) async throws -> Data {
        guard let value = properties[property] else {
            throw NativeCameraSessionError.connectionClosed
        }
        return value
    }
    func startRecording() async throws { commands.append("record-start") }
    func stopRecording() async throws { commands.append("record-stop") }
    func startRecording(admission: NikonCommandAdmission) async throws {
        try admission.require(owner: commandOwner)
        try admission.perform { commands.append("record-start") }
    }
    func stopRecording(admission: NikonCommandAdmission) async throws {
        try admission.require(owner: commandOwner)
        try admission.perform { commands.append("record-stop") }
    }
    private func send(_ write: PTPCameraPropertyWrite) {
        commands.append("write \(write.property)")
        writes.append(write)
        properties[write.property] = write.data
    }
    private func suspend() async {
        await withCheckedContinuation {
            held = $0
            waiting?.resume()
            waiting = nil
        }
    }
    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func release() {
        held?.resume()
        held = nil
    }
}
