import Foundation
import OpenCineCore
import Testing

@testable import OpenCineDJI

@MainActor
@Suite("DJI remote producer conveniences preserve native admission")
struct RemoteProducerAdmissionTests {
    @Test func suppliedISOKeepsItsReceiptAtDeferredPort() {
        let port = RemoteProducerPort()
        let session = DJICameraSessionAdapter(session: port)
        let admission = DJICommandAdmission(owner: port.owner, isCurrent: { true })
        let receipt = session.setISO(.iso800, admission: admission)
        #expect(receipt.stage == .admitted)
        #expect(port.pending.map(\.name) == ["ISO 800"])
        #expect(port.pending.map { $0.admission?.source } == [admission.source])
        port.enterNext()
        #expect(port.entered == ["ISO 800"])
        #expect(session.receipt(of: receipt.operation)?.stage == .sent)
        #expect(port.direct == 0)
    }

    @Test func whiteBalanceAndTintWritesKeepTheSameCapturedReceipt() {
        let port = RemoteProducerPort()
        let session = DJICameraSessionAdapter(session: port)
        let admission = DJICommandAdmission(owner: port.owner, isCurrent: { true })
        _ = session.setWhiteBalanceCustom(kelvin: 5679, tint: 7, admission: admission)
        #expect(port.pending.map(\.name) == ["WB 5700 0", "WB 5700 7"])
        #expect(port.pending.map { $0.admission?.source } == [admission.source, admission.source])
        port.enterNext()
        port.owner.replaceSource()
        port.enterNext()
        #expect(port.entered == ["WB 5700 0"])
        #expect(port.direct == 0)
    }

    @Test func autoWhiteBalanceWithNilTintPreservesThePendingTint() {
        let port = RemoteProducerPort()
        port.display.whiteBalance = .custom(kelvin: 5600, tint: -12)
        port.display.whiteBalanceTint = -12
        let session = DJICameraSessionAdapter(session: port)
        _ = session.setWhiteBalanceAuto(
            admission: .init(owner: port.owner, isCurrent: { true }))
        #expect(port.pending.map(\.name) == ["WB Auto -12"])
        port.enterNext()
        #expect(port.entered == ["WB Auto -12"])
    }

    @Test func confirmationKeepsApprovedTargetAndRefusesARepairedLink() {
        let port = RemoteProducerPort()
        let session = DJICameraSessionAdapter(session: port)
        let target = session.target
        port.link = .recovering
        session.linkDidChange()
        session.sessionDidChange()
        port.link = .ready
        session.sessionDidChange()
        #expect(session.target != target)
        let refused = session.record(
            start: true, aimedAt: target,
            admission: .init(owner: port.owner, isCurrent: { true }))
        #expect(refused.stage == .rejected(.staleEpoch))
        #expect(port.pending.isEmpty)
        #expect(port.entered.isEmpty)
    }

    @Test func currentConfirmationDispatchesOnceAndEnteredCompletionSurvivesRetirement() {
        let port = RemoteProducerPort()
        let session = DJICameraSessionAdapter(session: port)
        let receipt = session.record(
            start: true, aimedAt: session.target,
            admission: .init(owner: port.owner, isCurrent: { true }))
        port.enterNext()
        port.owner.replaceSource()
        port.enteredStage?(.acknowledged)
        port.status.isRecording = true
        session.sessionDidChange()
        #expect(port.entered == ["Record true"])
        #expect(session.receipt(of: receipt.operation)?.stage == .confirmed)
        #expect(port.pending.isEmpty)
    }

    @Test func photoRefusesExpiredReceiptAndDirectPhotoStillUsesTheOriginalPort() {
        let port = RemoteProducerPort()
        port.status.shootingMode = Int(ShootingMode.photo.rawValue)
        let session = DJICameraSessionAdapter(session: port)
        let old = DJICommandAdmission(owner: port.owner, isCurrent: { true })
        port.owner.replaceSource()
        let refused = session.shutter(aimedAt: session.target, admission: old)
        #expect(refused?.stage == .rejected(.authorityExpired))
        #expect(port.photos == 0)
        #expect(session.shutter(aimedAt: session.target) == nil)
        #expect(port.direct == 1)
        let current = DJICommandAdmission(owner: port.owner, isCurrent: { true })
        #expect(session.shutter(aimedAt: session.target, admission: current) == nil)
        #expect(port.photos == 1)
        #expect(port.direct == 1)
    }
}

@MainActor
private final class RemoteProducerPort: DJIControlPort {
    struct Pending {
        let name: String
        let admission: DJICommandAdmission?
        let stage: (@MainActor (ControlWireEvent) -> Void)?
    }
    let owner = DJICommandOwner()
    var commandOwner: DJICommandOwner? { owner }
    var status: CameraStatus = {
        var value = CameraStatus()
        value.shootingMode = 1
        value.recordingReported = true
        value.isoIndex = .iso100
        value.whiteBalance = .auto(tint: 0)
        value.whiteBalanceTint = 0
        return value
    }()
    lazy var display: CameraStatus = status
    var whiteBalanceDisplayStatus: CameraStatus { display }
    var currentShootingMode: ShootingMode? { ShootingMode.fromStatus(status.shootingMode) }
    var captureControlState: DJICaptureControlState? { nil }
    var connectedCameraID: String? { "SIMULATED remote producer" }
    var connectedModel: CameraModel? { .resolve(modelId: 0x0020, name: "Osmo Pocket 3") }
    var admitsMultiviewControl = true
    var isBusy = false
    var link = DJILinkState.ready
    var controlNote: String?
    var pending: [Pending] = []
    var entered: [String] = []
    var enteredStage: (@MainActor (ControlWireEvent) -> Void)?
    var direct = 0
    var photos = 0

    func enterNext() {
        let next = pending.removeFirst()
        guard next.admission?.admits(owner) ?? true else {
            next.stage?(.notSent)
            return
        }
        entered.append(next.name)
        enteredStage = next.stage
        next.stage?(.sent)
    }
    func setISO(
        _ index: IsoIndex, admission: DJICommandAdmission,
        onStage: (@MainActor (ControlWireEvent) -> Void)?
    ) {
        pending.append(
            .init(name: "ISO \(index.isoValue ?? 0)", admission: admission, stage: onStage))
    }
    func setRecording(
        _ start: Bool, admission: DJICommandAdmission,
        onStage: (@MainActor (ControlWireEvent) -> Void)?
    ) {
        pending.append(.init(name: "Record \(start)", admission: admission, stage: onStage))
    }
    func setWhiteBalanceAuto(
        tint: Int?, admission: DJICommandAdmission,
        onStage: (@MainActor (ControlWireEvent) -> Void)?
    ) {
        let tint = tint ?? display.whiteBalanceTint ?? 0
        display.whiteBalance = .auto(tint: tint)
        display.whiteBalanceTint = tint
        pending.append(.init(name: "WB Auto \(tint)", admission: admission, stage: onStage))
    }
    func setWhiteBalanceCustom(
        kelvin: Int, tint: Int, admission: DJICommandAdmission,
        onStage: (@MainActor (ControlWireEvent) -> Void)?
    ) {
        display.whiteBalance = .custom(kelvin: kelvin, tint: tint)
        display.whiteBalanceTint = tint
        pending.append(.init(name: "WB \(kelvin) \(tint)", admission: admission, stage: onStage))
    }
    func takePhoto(admission: DJICommandAdmission) {
        if admission.admits(owner) { photos += 1 }
    }
    func takePhoto() { direct += 1 }
    func setISO(_ index: IsoIndex, onStage: (@MainActor (ControlWireEvent) -> Void)?) {
        direct += 1
    }
    func setRecording(_ start: Bool, onStage: (@MainActor (ControlWireEvent) -> Void)?) {
        direct += 1
    }
    func setWhiteBalanceAuto(tint: Int?, onStage: (@MainActor (ControlWireEvent) -> Void)?) {
        direct += 1
    }
    func setWhiteBalanceCustom(
        kelvin: Int, tint: Int,
        onStage: (@MainActor (ControlWireEvent) -> Void)?
    ) { direct += 1 }
    func writeShutter(_ denominator: Int, onStage: @escaping @MainActor (ControlWireEvent) -> Void)
    { direct += 1 }
    func writeExposureCompensation(
        _ value: EvComp, onStage: @escaping @MainActor (ControlWireEvent) -> Void
    ) { direct += 1 }
    func writeFocusMode(
        _ value: OpenCineDJI.FocusMode, onStage: @escaping @MainActor (ControlWireEvent) -> Void
    ) { direct += 1 }
    func writeZoom(_ ratio: Double, onStage: @escaping @MainActor (ControlWireEvent) -> Void) {
        direct += 1
    }
}
