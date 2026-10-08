import Foundation
import OpenCineCore
import Testing

@testable import OpenCineDJI

@Suite("DJI explicit queued command admission")
struct DJICommandAdmissionTests {
    @Test func sourceReplacementAndPermanentCloseRetireOldReceipts() async throws {
        let owner = DJICommandOwner()
        let other = DJICommandOwner()
        let old = DJICommandAdmission(owner: owner, isCurrent: { true })
        #expect(old.admits(owner))
        #expect(!old.admits(other))
        owner.replaceSource()
        let oldFromExecutor = await Task.detached { old.isCurrent }.value
        #expect(!oldFromExecutor)
        let current = DJICommandAdmission(owner: owner, isCurrent: { true })
        #expect(current.source != old.source)
        #expect(current.isCurrent)
        owner.retire()
        owner.replaceSource()
        let afterClose = DJICommandAdmission(owner: owner, isCurrent: { true })
        #expect(!afterClose.isCurrent)
        #expect(throws: DJICommandAdmissionError.expired) { try afterClose.requireCurrent() }
    }

    @Test func anEnteredNativeCallCompletesAfterRevocation() throws {
        let owner = DJICommandOwner()
        let gate = DJIAdmissionTestGate()
        let admission = DJICommandAdmission(owner: owner, isCurrent: { gate.isCurrent })
        var entered = 0
        let result = try admission.perform {
            entered += 1
            gate.revoke()
            owner.replaceSource()
            return "original completion"
        }
        #expect(result == "original completion")
        #expect(entered == 1)
        #expect(throws: DJICommandAdmissionError.expired) {
            try admission.perform { entered += 1 }
        }
        #expect(entered == 1)
    }
}

@MainActor
@Suite("DJI adapter forwards each supplied native receipt")
struct DJICameraSessionAdmissionTests {
    @Test func sourceBoundAdmissionIsExplicitAndDirectOperationsRemainUnchanged() {
        let port = DJIAdmissionTestPort()
        let gate = DJIAdmissionTestGate()
        let admission = DJICommandAdmission(owner: port.nativeOwner, isCurrent: { gate.isCurrent })
        let session = DJICameraSessionAdapter(session: port)
        let supplied = session.request(.set(.iso(.manual(800))), admission: admission)
        #expect(supplied.stage == .admitted)
        #expect(port.pending.map { $0.admission.source } == [admission.source])
        gate.revoke()
        port.deliverNext()
        #expect(session.receipt(of: supplied.operation)?.stage == .failed(.notSent))
        #expect(port.writes.isEmpty)
        let direct = session.request(.set(.iso(.manual(400))))
        #expect(direct.stage == .sent)
        #expect(port.writes == [.iso400])
    }

    @Test func independentQueuedReceiptsDoNotBorrowEachOthersAuthority() {
        let port = DJIAdmissionTestPort()
        let firstGate = DJIAdmissionTestGate()
        let secondGate = DJIAdmissionTestGate()
        let session = DJICameraSessionAdapter(session: port)
        let first = session.request(
            .set(.iso(.manual(800))),
            admission:
                .init(owner: port.nativeOwner, isCurrent: { firstGate.isCurrent }))
        let second = session.request(
            .set(.iso(.manual(400))),
            admission:
                .init(owner: port.nativeOwner, isCurrent: { secondGate.isCurrent }))
        firstGate.revoke()
        port.deliverNext()
        port.deliverNext()
        #expect(session.receipt(of: first.operation)?.stage == .failed(.notSent))
        #expect(session.receipt(of: second.operation)?.stage == .sent)
        #expect(port.writes == [.iso400])
    }

    @Test func replacedNativeSourceAndWrongOwnerSendNothing() {
        let port = DJIAdmissionTestPort()
        let session = DJICameraSessionAdapter(session: port)
        let old = DJICommandAdmission(owner: port.nativeOwner, isCurrent: { true })
        let pending = session.request(.set(.iso(.manual(800))), admission: old)
        port.nativeOwner.replaceSource()
        port.deliverNext()
        #expect(session.receipt(of: pending.operation)?.stage == .failed(.notSent))
        #expect(
            session.request(.set(.iso(.manual(400))), admission: old).stage
                == .rejected(.authorityExpired))
        #expect(
            session.request(
                .set(.iso(.manual(400))),
                admission:
                    .init(owner: DJICommandOwner(), isCurrent: { true })
            ).stage == .rejected(.authorityExpired))
        #expect(port.writes.isEmpty)
    }

    @Test func unavailableSuppliedPortNeverFallsThroughToDirectWrite() {
        let port = DJIAdmissionTestPort()
        let session = DJICameraSessionAdapter(session: port)
        let supplied = session.request(
            .set(.whiteBalance(.kelvin(5600))),
            admission:
                .init(owner: port.nativeOwner, isCurrent: { true }))
        #expect(supplied.stage == .failed(.notSent))
        #expect(port.otherDirectWrites == 0)
        _ = session.request(.set(.whiteBalance(.kelvin(5600))))
        #expect(port.otherDirectWrites == 1)
    }

    @Test func enteredWriteKeepsItsAcknowledgementAndReadbackAfterRevocation() {
        let port = DJIAdmissionTestPort()
        let gate = DJIAdmissionTestGate()
        let session = DJICameraSessionAdapter(session: port)
        let receipt = session.request(
            .set(.iso(.manual(800))),
            admission:
                .init(owner: port.nativeOwner, isCurrent: { gate.isCurrent }))
        port.deliverNext()
        gate.revoke()
        port.stage?(.acknowledged)
        #expect(session.receipt(of: receipt.operation)?.stage == .awaitingObservation)
        port.status.isoIndex = .iso800
        session.sessionDidChange()
        #expect(session.receipt(of: receipt.operation)?.stage == .confirmed)
        #expect(port.writes == [.iso800])
    }

    @Test func closeDoesNotDispatchQueuedCommands() {
        let port = DJIAdmissionTestPort()
        let session = DJICameraSessionAdapter(session: port)
        let receipt = session.request(
            .set(.iso(.manual(800))),
            admission:
                .init(owner: port.nativeOwner, isCurrent: { true }))
        session.close(.requested)
        port.nativeOwner.retire()
        port.deliverNext()
        #expect(session.receipt(of: receipt.operation)?.isFinished == true)
        #expect(port.writes.isEmpty)
    }
}

private final class DJIAdmissionTestGate: @unchecked Sendable {
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

@MainActor
private final class DJIAdmissionTestPort: DJIControlPort {
    struct Pending {
        let index: IsoIndex
        let admission: DJICommandAdmission
        let stage: (@MainActor (ControlWireEvent) -> Void)?
    }
    let nativeOwner = DJICommandOwner()
    var commandOwner: DJICommandOwner? { nativeOwner }
    var status: CameraStatus = {
        var value = CameraStatus()
        value.shootingMode = 1
        value.recordingReported = true
        value.isoIndex = .iso100
        value.whiteBalance = .auto(tint: 0)
        return value
    }()
    var whiteBalanceDisplayStatus: CameraStatus { status }
    var currentShootingMode: ShootingMode? { ShootingMode.fromStatus(status.shootingMode) }
    var captureControlState: DJICaptureControlState? { nil }
    var connectedCameraID: String? { "SIMULATED pocket" }
    var connectedModel: CameraModel? { .resolve(modelId: 0x0020, name: "Osmo Pocket 3") }
    var admitsMultiviewControl = true
    var isBusy = false
    var link = DJILinkState.ready
    var controlNote: String?
    var writes: [IsoIndex] = []
    var otherDirectWrites = 0
    var pending: [Pending] = []
    var stage: (@MainActor (ControlWireEvent) -> Void)?

    func deliverNext() {
        let next = pending.removeFirst()
        guard next.admission.admits(nativeOwner) else {
            next.stage?(.notSent)
            return
        }
        writes.append(next.index)
        stage = next.stage
        next.stage?(.sent)
    }
    func setISO(
        _ index: IsoIndex, admission: DJICommandAdmission,
        onStage: (@MainActor (ControlWireEvent) -> Void)?
    ) {
        pending.append(.init(index: index, admission: admission, stage: onStage))
    }
    func setISO(_ index: IsoIndex, onStage: (@MainActor (ControlWireEvent) -> Void)?) {
        writes.append(index)
        stage = onStage
        onStage?(.sent)
    }
    func takePhoto() { otherDirectWrites += 1 }
    func setRecording(_ start: Bool, onStage: (@MainActor (ControlWireEvent) -> Void)?) {
        otherDirectWrites += 1
    }
    func setWhiteBalanceAuto(tint: Int?, onStage: (@MainActor (ControlWireEvent) -> Void)?) {
        otherDirectWrites += 1
    }
    func setWhiteBalanceCustom(
        kelvin: Int, tint: Int,
        onStage: (@MainActor (ControlWireEvent) -> Void)?
    ) { otherDirectWrites += 1 }
    func writeShutter(_ denominator: Int, onStage: @escaping @MainActor (ControlWireEvent) -> Void)
    { otherDirectWrites += 1 }
    func writeExposureCompensation(
        _ value: EvComp, onStage: @escaping @MainActor (ControlWireEvent) -> Void
    ) { otherDirectWrites += 1 }
    func writeFocusMode(
        _ value: OpenCineDJI.FocusMode,
        onStage: @escaping @MainActor (ControlWireEvent) -> Void
    ) { otherDirectWrites += 1 }
    func writeZoom(_ ratio: Double, onStage: @escaping @MainActor (ControlWireEvent) -> Void) {
        otherDirectWrites += 1
    }
}
