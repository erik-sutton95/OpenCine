import OpenCineCore
import Testing

@testable import OpenCineDJI

@MainActor
@Suite struct DJIControlSessionBindingTests {
    @Test func ownedCloseReleasesNativeOwnerExactlyOnce() {
        let port = BindingPort()
        var closes: [SessionCloseReason] = []
        let binding = DJIControlSessionBinding(
            port: port, onClose: { closes.append($0) }, now: clock)
        #expect(binding.cached == nil)
        let session = binding.session
        #expect(binding.session === session)
        session.close(.requested)
        session.close(.replaced)
        #expect(closes == [.requested])
        #expect(binding.cached == nil)
        #expect(session.current.connection == .disconnected(.requested))
        #expect(port.fired.isEmpty)
    }

    @Test func replacementAndLateCloseCannotReleaseSuccessor() {
        let port = BindingPort()
        var closes: [SessionCloseReason] = []
        let binding = DJIControlSessionBinding(
            port: port, onClose: { closes.append($0) }, now: clock)
        let first = binding.session
        let oldCommand = CameraCommand(
            .startRecording, preconditions: CommandPreconditions(first.current))
        binding.beginConnection()
        port.connectedCameraID = "camera-b"
        let successor = binding.session
        #expect(first.id != successor.id)
        #expect(first.current.connection == .disconnected(.replaced))
        first.close(.requested)
        #expect(first.submit(oldCommand).stage == .rejected(.sessionClosed))
        #expect(binding.session === successor)
        #expect(successor.current.connection == .ready)
        #expect(closes.isEmpty)
        #expect(port.fired.isEmpty)
        successor.close(.requested)
        #expect(closes == [.requested])
    }

    @Test func recoveryKeepsIdentityButRejectsOldLinkCommand() {
        let port = BindingPort()
        var closes: [SessionCloseReason] = []
        let binding = DJIControlSessionBinding(
            port: port, onClose: { closes.append($0) }, now: clock)
        let session = binding.session
        let before = session.current
        port.link = .recovering
        session.linkDidChange()
        #expect(binding.session === session)
        #expect(session.current.epoch != before.epoch)
        port.link = .ready
        let command = CameraCommand(.startRecording, preconditions: CommandPreconditions(before))
        #expect(session.submit(command).stage == .rejected(.staleEpoch))
        #expect(closes.isEmpty)
        #expect(port.fired.isEmpty)
    }

    @Test func nativeTeardownAndBorrowedReturnRetireWithoutClosingOwner() {
        let port = BindingPort()
        var nativeCloses = 0
        let binding = DJIControlSessionBinding(
            port: port, onClose: { _ in nativeCloses += 1 }, now: clock)
        let borrowed = binding.session
        binding.retire(.requested)
        binding.retire(.requested)
        borrowed.close(.requested)
        #expect(borrowed.current.connection == .disconnected(.requested))
        #expect(nativeCloses == 0)
        #expect(port.fired.isEmpty)
        #expect(binding.session.id != borrowed.id)
    }

    @Test func reentrantNativeTeardownCannotCloseAgain() {
        let port = BindingPort()
        var nativeCloses = 0
        var teardown: (() -> Void)?
        let binding = DJIControlSessionBinding(
            port: port,
            onClose: { _ in
                nativeCloses += 1
                teardown?()
            }, now: clock)
        let session = binding.session
        teardown = { [weak binding] in binding?.retire(.requested) }
        session.close(.requested)
        #expect(nativeCloses == 1)
        #expect(binding.cached == nil)
        #expect(session.current.connection == .disconnected(.requested))
    }

    @Test func closeWhileRecordingNeverSendsStopRecord() {
        let port = BindingPort()
        port.status.isRecording = true
        var nativeCloses = 0
        let binding = DJIControlSessionBinding(
            port: port, onClose: { _ in nativeCloses += 1 }, now: clock)
        let session = binding.session
        #expect(session.current.recording.value == .recording)
        session.close(.requested)
        #expect(nativeCloses == 1)
        #expect(port.fired.isEmpty)
        #expect(port.status.isRecording)
    }

    private var clock: @Sendable () -> MonotonicInstant { { MonotonicInstant(.seconds(10)) } }
}

@MainActor
private final class BindingPort: DJIControlPort {
    var status: CameraStatus = {
        var status = CameraStatus()
        status.shootingMode = 1
        status.recordingReported = true
        return status
    }()
    var whiteBalanceDisplayStatus: CameraStatus { status }
    var currentShootingMode: ShootingMode? { ShootingMode.fromStatus(status.shootingMode) }
    var connectedCameraID: String? = "camera-a"
    var connectedModel: CameraModel? = CameraModel.resolve(modelId: 0x0020, name: "Osmo Pocket 3")
    var admitsMultiviewControl = true
    var isBusy = false
    var link = DJILinkState.ready
    var controlNote: String?
    private(set) var fired: [String] = []

    func takePhoto() { fired.append("photo") }
    func setISO(_ index: IsoIndex, onStage: (@MainActor (ControlWireEvent) -> Void)?) {
        fired.append("iso")
    }
    func setRecording(_ start: Bool, onStage: (@MainActor (ControlWireEvent) -> Void)?) {
        fired.append("record \(start)")
    }
    func setWhiteBalanceAuto(tint: Int?, onStage: (@MainActor (ControlWireEvent) -> Void)?) {
        fired.append("wb")
    }
    func setWhiteBalanceCustom(
        kelvin: Int, tint: Int, onStage: (@MainActor (ControlWireEvent) -> Void)?
    ) { fired.append("wb") }
}
