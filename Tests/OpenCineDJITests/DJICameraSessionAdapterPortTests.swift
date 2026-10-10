import OpenCineCore
import OpenCineMotion
import Testing

@testable import OpenCineDJI

/// The DJI seam against a fake port: a neutral harness instantiates the adapter without the
/// Pocket app (VENDOR-01 gate). The Pocket iOS `DJICameraSessionAdapterTests` cover the same
/// adapter through the real app session and loopback datalink.
@MainActor
@Suite struct DJICameraSessionAdapterPortTests {
    @Test func everyDeclaredCapabilityReachesThePort() throws {
        let probe = FakePort()  // the adapter holds its port unowned, as the app session owns it
        let keys = DJICameraSessionAdapter(session: probe).current.capabilities.descriptors.keys
        #expect(Set(keys) == [.iso, .whiteBalance, .whiteBalanceTint, .recording])
        for key in keys {
            let port = FakePort()
            let seam = DJICameraSessionAdapter(session: port)
            let snapshot = seam.current
            let intent = try #require(Self.validIntent(for: key, in: snapshot), "\(key)")
            let receipt = seam.submit(
                CameraCommand(intent, preconditions: CommandPreconditions(snapshot)))
            #expect(receipt.stage == .admitted, "\(key) is declared, so it must reach the port")
            #expect(port.fired.count == 1)
        }
    }

    /// MULTI-03 F6: the body's own flags say what it cannot do; an unknown body claims nothing.
    @Test func fixedApertureBodyListsApertureUnsupported() {
        let port = FakePort()
        let seam = DJICameraSessionAdapter(session: port)
        #expect(seam.current.capabilities.support(of: .aperture) == .unsupported)
        #expect(seam.current.capabilities.support(of: .shutter) == .unknown)
        #expect(seam.request(.set(.aperture(2))).stage == .rejected(.unsupported))
        port.connectedModel = nil
        #expect(seam.current.capabilities.support(of: .aperture) == .unknown)
    }

    /// SHELL-01: what each body publishes and the layout it projects to over an app base that
    /// carries only clip delete, clip star and the internet hop.
    @Test func eachBodyPublishesItsLayout() {
        var base = MonitorLayoutCapabilities()
        base.clipDelete = true
        base.clipStar = true
        base.requiresInternetHop = true
        func expected(
            gimbal: Bool, zoom: Bool, focus: Bool, iris: Bool, timecode: Bool, audio: Bool
        ) -> MonitorLayoutCapabilities {
            var layout = base
            (layout.gimbal, layout.headTracking) = (gimbal, gimbal)
            (layout.zoom, layout.focus, layout.iris) = (zoom, focus, iris)
            (layout.timecode, layout.audio) = (timecode, audio)
            return layout
        }
        let bodies: [(Int, String, MonitorLayoutCapabilities, SupportStatus)] = [
            (0x0022, "Osmo Pocket 4 Pro", expected(gimbal: true, zoom: true, focus: true, iris: false, timecode: true, audio: true), .supported),
            (0x0020, "Osmo Pocket 3", expected(gimbal: true, zoom: true, focus: true, iris: false, timecode: true, audio: true), .supported),
            (0x0018, "Osmo Action 6", expected(gimbal: false, zoom: false, focus: false, iris: true, timecode: true, audio: true), .supported),
            (0x0019, "Osmo Nano", expected(gimbal: false, zoom: false, focus: false, iris: false, timecode: false, audio: true), .unsupported),
        ]
        for (id, name, layout, timecode) in bodies {
            let port = FakePort()
            port.connectedModel = CameraModel.resolve(modelId: id, name: name)
            let seam = DJICameraSessionAdapter(session: port)
            #expect(seam.layout(base: base) == layout, "\(name)")
            #expect(seam.current.capabilities.timecode == timecode, "\(name)")
            #expect(seam.current.capabilities.audioLevels == .supported, "\(name)")
            #expect((port.connectedModel?.motion != nil) == layout.gimbal, "\(name)")
        }
        // No camera: nothing is claimed, so the layout is the base.
        let port = FakePort()
        port.connectedModel = nil
        let seam = DJICameraSessionAdapter(session: port)
        #expect(seam.layout(base: base) == base)
        #expect(seam.current.capabilities.timecode == .unknown)
        #expect(seam.current.capabilities.audioLevels == .unknown)
    }

    @Test func pocketGimbalReportsPoseInsideItsReach() {
        let gimbal = MotionCapabilities.pocketGimbal
        #expect(gimbal.pose == .supported)
        #expect(gimbal.bounds == GimbalReach.bounds)
        #expect(gimbal.axes == [.pan, .tilt, .zoom])
        #expect(gimbal.target(GimbalWaypoint(yawDeg: 226, pitchDeg: 0, zoom: 1)) == nil)
    }

    @Test func timecodeAndAudioLevelsAreCameraReportedOrUnknown() {
        let port = FakePort()
        let seam = DJICameraSessionAdapter(session: port)
        #expect(seam.current.timecode == .unknown)
        #expect(seam.current.audioLevels == .unknown, "no report is unknown, never silence")
        port.status.timecode = "05:22:47:18"
        port.status.audioMeters = AudioMeterLevels(
            left: AudioMeterChannel(levelDB: -18, peakDB: -12, peakAge: 0.4),
            right: AudioMeterChannel(levelDB: -20, peakDB: -14))
        let snapshot = seam.current
        #expect(snapshot.timecode.value == CameraTimecode(hours: 5, minutes: 22, seconds: 47, frames: 18))
        #expect(snapshot.timecode.origin == .cameraReported)
        #expect(
            snapshot.audioLevels.value
                == AudioLevels(left: .init(level: -18, peak: -12), right: .init(level: -20, peak: -14)))
        #expect(snapshot.audioLevels.origin == .cameraReported)
        port.status.timecode = "--:--"
        #expect(seam.current.timecode == .unknown)
    }

    @Test func captureCapabilitiesUseActualReportsAndReachThePort() {
        let targets: [(SettingValue, String)] = [
            (.shutter(.duration(Rational(1, 100))), "shutter 100"),
            (.exposureCompensation(Rational(2, 3)), "ev 2"),
            (.focusMode(.continuous), "focus 2"),
            (.zoom(2), "zoom 2.0"),
        ]
        for (value, call) in targets {
            let port = Self.capturePort()
            let seam = DJICameraSessionAdapter(session: port)
            let receipt = seam.request(.set(value))
            #expect(receipt.stage == .admitted)
            #expect(port.fired == [call])
            port.stage(.sent)
            port.stage(.confirmed)  // Legacy settlement cannot substitute for a camera report.
            #expect(seam.receipt(of: receipt.operation)?.stage == .awaitingObservation)
            #expect(seam.current.value(of: value.key).value != value)
        }
    }

    @Test func optimisticFocusCannotConfirmOrReplaceReportedFocus() {
        let port = Self.capturePort()
        let seam = DJICameraSessionAdapter(session: port)
        let receipt = seam.request(.set(.focusMode(.continuous)))
        port.stage(.sent)
        port.status.focusMode = .continuous
        seam.sessionDidChange()
        #expect(seam.receipt(of: receipt.operation)?.stage == .sent)
        #expect(seam.current.value(of: .focusMode).value == .focusMode(.single))
        port.captureControlState?.reported.focusMode = .continuous
        seam.sessionDidChange()
        #expect(seam.receipt(of: receipt.operation)?.stage == .confirmed)
    }

    @Test func actualZoomReportCanConfirmBeforeAnAck() {
        let port = Self.capturePort()
        let seam = DJICameraSessionAdapter(session: port)
        let receipt = seam.request(.set(.zoom(2)))
        port.stage(.sent)
        port.captureControlState?.reported.zoomLens = CamFov.lensPosition(for: 2)
        seam.sessionDidChange()
        #expect(seam.receipt(of: receipt.operation)?.stage == .confirmed)
        port.stage(.refused)
        #expect(seam.receipt(of: receipt.operation)?.stage == .confirmed)
    }

    @Test func changedCaptureDomainRejectsQueuedEdit() {
        let port = Self.capturePort()
        let seam = DJICameraSessionAdapter(session: port)
        let command = CameraCommand(.set(.shutter(.duration(Rational(1, 100)))),
                                    preconditions: CommandPreconditions(seam.current))
        port.captureControlState?.reported.availableShutterDenoms = [50]
        #expect(seam.submit(command).stage == .rejected(.staleCapabilities))
        #expect(port.fired.isEmpty)
    }

    @Test func commonShutterNeverChangesExposureModeImplicitly() {
        let port = Self.capturePort()
        port.captureControlState?.reported.expoMode = .auto
        let seam = DJICameraSessionAdapter(session: port)
        #expect(seam.request(.set(.shutter(.duration(Rational(1, 100))))).stage
                == .rejected(.unavailable(.mode)))
        #expect(port.fired.isEmpty)
    }

    @Test func captureUnknownsStayNilAndMechanicalIrisIsReadOnly() {
        let port = Self.capturePort()
        port.connectedModel = CameraModel.resolve(modelId: 0x0018, name: "Osmo Action 6")
        port.captureControlState = DJICaptureControlState(reported: CameraStatus(), model: port.connectedModel)
        let seam = DJICameraSessionAdapter(session: port)
        for key in [SettingKey.shutter, .exposureCompensation, .focusMode, .zoom, .aperture] {
            #expect(seam.current.value(of: key).value == nil)
        }
        port.captureControlState?.reported.irisHundredths = 280
        #expect(seam.current.value(of: .aperture).value == .aperture(2.8))
        #expect(seam.request(.set(.aperture(2))).stage == .rejected(.readOnly))
        #expect(port.fired.isEmpty)
    }

    private static func capturePort() -> FakePort {
        let port = FakePort()
        var actual = CameraStatus()
        actual.expoMode = .manual
        actual.shutterDenom = 50
        actual.availableShutterDenoms = [50, 100]
        actual.evComp = .zero
        actual.focusMode = .single
        actual.zoomLens = CamFov.lensPosition(for: 1)
        port.captureControlState = DJICaptureControlState(reported: actual, model: port.connectedModel)
        return port
    }

    @Test func undeclaredSettingStaysUnknown() {
        let port = FakePort()
        let receipt = DJICameraSessionAdapter(session: port)
            .request(.set(.shutter(.duration(Rational(1, 50)))))
        #expect(receipt.stage == .rejected(.supportUnknown))
        #expect(port.fired.isEmpty)
    }

    @Test func isoIsConfirmedOnlyByTheCameraReport() {
        let port = FakePort()
        let seam = DJICameraSessionAdapter(session: port)
        let receipt = seam.setISO(.iso800)
        #expect(port.fired == ["iso 6"])
        port.stage(.sent)
        port.stage(.acknowledged)
        #expect(seam.receipt(of: receipt.operation)?.stage == .awaitingObservation)
        port.status.isoIndex = .iso800
        seam.sessionDidChange()
        #expect(seam.receipt(of: receipt.operation)?.stage == .confirmed)
        #expect(seam.current.value(of: .iso).value == .iso(.manual(800)))
    }

    /// A control model that binds after the session changed starts from it (Kotlin twin).
    @Test func lateFollowerStartsFromTheSessionAsItIsNow() async throws {
        let port = FakePort()
        let seam = DJICameraSessionAdapter(session: port)
        port.status.isoIndex = .iso800
        seam.sessionDidChange()  // nobody follows yet: nothing is rebuilt
        var follower = seam.snapshots().makeAsyncIterator()
        let first = try #require(await follower.next())
        #expect(first.connection == .ready)
        #expect(first.capabilities[.iso] != nil, "The first snapshot describes the camera")
        #expect(first.value(of: .iso).value == .iso(.manual(800)))
    }

    @Test func cameraRefusalIsRejected() {
        let port = FakePort()
        let seam = DJICameraSessionAdapter(session: port)
        let receipt = seam.setWhiteBalanceCustom(kelvin: 5_600, tint: 0)
        #expect(port.fired == ["wb 5600 0"])
        port.stage(.refused)
        #expect(seam.receipt(of: receipt.operation)?.stage == .rejected(.cameraRefused))
    }

    @Test func unknownRecordingStateNeverReachesThePort() {
        let port = FakePort()
        port.status.recordingReported = false
        let receipt = DJICameraSessionAdapter(session: port).record(start: true)
        #expect(receipt.stage == .rejected(.recordingStateUnknown))
        #expect(port.fired.isEmpty)
        #expect(port.controlNote == "Waiting for the camera's record state")
    }

    @Test func startWhileRecordingSendsNothing() {
        let port = FakePort()
        port.status.isRecording = true
        let receipt = DJICameraSessionAdapter(session: port).record(start: true)
        #expect(receipt.stage == .confirmed)
        #expect(port.fired.isEmpty)
    }

    @Test func linkStateMapsToCoreConnection() {
        let port = FakePort()
        let seam = DJICameraSessionAdapter(session: port)
        #expect(seam.current.connection == .ready)
        port.link = .connecting(.awaitingApproval)
        guard case .connecting(let attempt, .awaitingApproval) = seam.current.connection else {
            Issue.record("expected connecting(awaitingApproval)")
            return
        }
        port.link = .connecting(.negotiating)
        #expect(seam.current.connection == .connecting(attempt, .negotiating), "same attempt")
        port.link = .recovering
        #expect(seam.current.connection == .recovering(attempt))
        port.link = .notLinked
        #expect(seam.current.connection == .discovered)
        #expect(seam.current.authority == .unavailable(.link))
    }

    @Test func replacedLinkEndsInFlightWork() {
        let port = FakePort()
        let seam = DJICameraSessionAdapter(session: port)
        let receipt = seam.setISO(.iso400)
        port.stage(.sent)
        seam.linkDidChange()
        #expect(seam.receipt(of: receipt.operation)?.stage == .outcomeUnknown)
    }

    @Test func closeNeverSendsACommand() {
        let port = FakePort()
        port.status.isRecording = true
        let seam = DJICameraSessionAdapter(session: port)
        seam.close(.requested)
        #expect(port.fired.isEmpty)
        #expect(seam.current.connection == .disconnected(.requested))
    }

    private static func validIntent(for key: SettingKey, in snapshot: CameraSnapshot)
        -> CameraCommandIntent?
    {
        let current = snapshot.value(of: key).value
        switch key {
        case .recording:
            return snapshot.recording.value == .recording ? .stopRecording : .startRecording
        case .iso:
            return snapshot.capabilities[key]?.domain?.choices.first { $0 != current }.map {
                .set($0)
            }
        case .whiteBalance:
            return .set(.whiteBalance(.kelvin(4_300)))
        case .whiteBalanceTint:
            return .set(.whiteBalanceTint(12))
        default:
            return nil
        }
    }
}

/// A linked, idle Pocket in video mode reporting Auto white balance. Records every wire call.
@MainActor
private final class FakePort: DJIControlPort {
    var status: CameraStatus = {
        var status = CameraStatus()
        status.shootingMode = 1
        status.recordingReported = true
        status.isoIndex = .iso100
        status.whiteBalance = .auto(tint: 0)
        status.batteryPercent = 80
        return status
    }()
    var whiteBalanceDisplayStatus: CameraStatus { status }
    var currentShootingMode: ShootingMode? { ShootingMode.fromStatus(status.shootingMode) }
    var captureControlState: DJICaptureControlState?
    var connectedCameraID: String? = "fake-pocket"
    var connectedModel: CameraModel? = CameraModel.resolve(modelId: 0x0020, name: "Osmo Pocket 3")
    var admitsMultiviewControl = true
    var isBusy = false
    var link = DJILinkState.ready
    var controlNote: String?

    private(set) var fired: [String] = []
    private var onStage: (@MainActor (ControlWireEvent) -> Void)?

    func stage(_ event: ControlWireEvent) { onStage?(event) }

    func takePhoto() { fired.append("photo") }

    func setISO(_ index: IsoIndex, onStage: (@MainActor (ControlWireEvent) -> Void)?) {
        fire("iso \(index.rawValue)", onStage)
    }

    func setRecording(_ start: Bool, onStage: (@MainActor (ControlWireEvent) -> Void)?) {
        fire("record \(start)", onStage)
    }

    func setWhiteBalanceAuto(tint: Int?, onStage: (@MainActor (ControlWireEvent) -> Void)?) {
        fire("wb auto \(tint ?? 0)", onStage)
    }

    func setWhiteBalanceCustom(
        kelvin: Int, tint: Int, onStage: (@MainActor (ControlWireEvent) -> Void)?
    ) {
        fire("wb \(kelvin) \(tint)", onStage)
    }

    func writeShutter(_ denominator: Int, onStage: @escaping @MainActor (ControlWireEvent) -> Void) {
        fire("shutter \(denominator)", onStage)
    }
    func writeExposureCompensation(_ value: EvComp, onStage: @escaping @MainActor (ControlWireEvent) -> Void) {
        fire("ev \(value.thirds)", onStage)
    }
    func writeFocusMode(_ value: OpenCineDJI.FocusMode, onStage: @escaping @MainActor (ControlWireEvent) -> Void) {
        fire("focus \(value.rawValue)", onStage)
    }
    func writeZoom(_ ratio: Double, onStage: @escaping @MainActor (ControlWireEvent) -> Void) {
        fire("zoom \(ratio)", onStage)
    }

    private func fire(_ call: String, _ onStage: (@MainActor (ControlWireEvent) -> Void)?) {
        fired.append(call)
        self.onStage = onStage
    }
}
