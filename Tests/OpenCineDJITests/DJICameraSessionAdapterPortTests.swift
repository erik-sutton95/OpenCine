import OpenCineCore
import OpenCineMotion
import OpenCineMedia
import Testing

@testable import OpenCineDJI

/// The DJI seam against a fake port: a neutral harness instantiates the adapter without the
/// Pocket app (VENDOR-01 gate). The Pocket iOS `DJICameraSessionAdapterTests` cover the same
/// adapter through the real app session and loopback datalink.
@MainActor
@Suite struct DJICameraSessionAdapterPortTests {
    /// Hardware pass 7.5 and 8.4: the shared storage cycle reads the DJI wire storage as every
    /// app does: whole-unit free space, percentage, then the camera's own remaining time.
    @Test func storageReadsTheSharedStorageCycle() {
        var status = CameraStatus()
        status.storageTotalMb = 128_000
        status.storageFreeMb = 109_568
        status.recordRemainingSec = 3_000
        let storage = DJICameraSessionAdapter.storage(status)
        #expect(StorageReadoutCycle.forms(storage, photo: false) == ["115GB", "86%", "50 Min"])
        #expect(StorageReadoutCycle.forms(storage, photo: true) == ["115GB", "86%"])
        status.recordRemainingSec = 0
        #expect(
            StorageReadoutCycle.forms(DJICameraSessionAdapter.storage(status), photo: false)
                == ["115GB", "86%"])
    }

    @Test func recordingFactsUseReportedDimensionsAndNeverPreviewCodec() {
        let port = FakePort()
        port.status.videoResolution = .p4K_4x3
        port.status.videoFormat = VideoFormat(resolution: .p4K_4x3, frameRate: .fps25)
        port.status.fps = 25
        port.status.colorMode = .dLog2
        port.status.expoMode = .manual
        let seam = DJICameraSessionAdapter(session: port)
        let format = seam.current.recordingFormat
        #expect(seam.current.exposureProgram.value == .manual)
        #expect(format.dimensions.value == CameraRecordingFormat.Dimensions(width: 3840, height: 2880))
        #expect(format.dimensions.origin == .cameraReported)
        #expect(format.profile.value == "D-Log2")
        #expect(format.codec.value == nil, "The preview codec does not declare the recording codec")
        port.status.videoResolution = VideoResolution(rawValue: 0xFF)
        port.status.videoFormat = nil
        port.status.colorMode = nil
        port.status.expoMode = nil
        #expect(seam.current.exposureProgram == .unknown)
        #expect(seam.current.recordingFormat == .unknown)
        #expect(port.fired.isEmpty)
    }

    /// OPENPOCKETCINE-IOS-44: SwiftUI bodies read `current` many times per frame. A read with the
    /// same session state reuses the snapshot; each input the mapping reads rebuilds it once.
    @Test func repeatedReadsReuseTheSnapshotUntilTheSessionChanges() {
        let port = FakePort()
        let seam = DJICameraSessionAdapter(session: port)
        let first = seam.current
        for _ in 0..<50 { _ = seam.current }
        _ = seam.controlCapabilities()
        _ = seam.layout()
        #expect(seam.snapshotBuilds == 1)
        #expect(seam.current == first)

        port.status.isoIndex = .iso400
        #expect(seam.current.settings[.iso]?.value == .iso(.manual(400)))
        _ = seam.current
        #expect(seam.snapshotBuilds == 2)

        port.isBusy = true
        #expect(seam.current.capabilities.descriptors[.recording]?.availability == .unavailable(.busy))
        port.link = .recovering
        #expect(seam.current.authority == .unavailable(.link))
        port.admitsMultiviewControl = false
        port.link = .ready
        #expect(seam.current.authority == .unavailable(.authority))
        port.connectedCameraID = "another"
        _ = seam.current
        port.connectedModel = nil
        #expect(seam.current.capabilities.unsupported.isEmpty)
        port.captureControlState = DJICaptureControlState(reported: port.status, model: port.connectedModel)
        _ = seam.current
        seam.linkDidChange()
        _ = seam.current
        _ = seam.current
        #expect(seam.snapshotBuilds == 9)
    }

    /// SIMULATED Nano report: the recording profile reads in the body's own colour names.
    @Test func recordingProfileUsesTheBodyColourNames() {
        let port = FakePort()
        port.connectedModel = CameraModel.resolve(modelId: 0x0019, name: "OsmoNano-5A31")
        port.status.colorMode = .normal
        let seam = DJICameraSessionAdapter(session: port)
        #expect(seam.current.recordingFormat.profile.value == "Normal 8-bit")
        port.status.colorMode = .dLogM
        seam.sessionDidChange()
        #expect(seam.current.recordingFormat.profile.value == "D-Log M 10-bit")
    }

    /// SIMULATED complete battery reports; false and true differ from no report.
    @Test func batteryChargingReportsReachCommonPower() {
        let port = FakePort()
        port.status = CameraStatus()
        let seam = DJICameraSessionAdapter(session: port)
        #expect(seam.current.power.charging.value == nil)
        for flag: UInt8 in [0, 1] {
            var payload = [UInt8](repeating: 0, count: 34)
            payload[20] = 68
            payload[32] = flag
            CameraStatusDecoder.apply(Duml.Frame(sender: 0, receiver: 0, seq: 0, flags: 0,
                cmdSet: 0x0D, cmdId: 0x02, payload: payload), to: &port.status)
            seam.sessionDidChange()
            #expect(seam.current.power.charging.value == (flag == 1))
            #expect(seam.current.power.charging.origin == .cameraReported)
        }
        var invalid = [UInt8](repeating: 0, count: 34)
        invalid[20] = 68
        invalid[32] = 2
        CameraStatusDecoder.apply(Duml.Frame(sender: 0, receiver: 0, seq: 0, flags: 0,
            cmdSet: 0x0D, cmdId: 0x02, payload: invalid), to: &port.status)
        seam.sessionDidChange()
        #expect(seam.current.power.charging.value == nil)
    }

    @Test func legacyTimecodeHelpersRetainSupportAndCompleteFrames() throws {
        let support: SupportStatus = DJICameraSessionAdapter.timecodeSupport(nil)
        #expect(support == .unknown)
        #expect(DJICameraSessionAdapter.timecodeCapability(nil) == .unknown)
        let value = try #require(DJICameraSessionAdapter.timecode("05:22:47:18"))
        let frames: Int = value.frames
        #expect(frames == 18)
        #expect(DJICameraSessionAdapter.timecode("05:22:47") == nil)
    }

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
        let bodies: [(Int, String, MonitorLayoutCapabilities, TimecodeCapability)] = [
            (0x0022, "Osmo Pocket 4 Pro", expected(gimbal: true, zoom: true, focus: true, iris: false, timecode: true, audio: true), .supported(.seconds)),
            (0x0020, "Osmo Pocket 3", expected(gimbal: true, zoom: true, focus: true, iris: false, timecode: true, audio: true), .supported(.seconds)),
            (0x0018, "Osmo Action 6", expected(gimbal: false, zoom: false, focus: false, iris: true, timecode: true, audio: true), .supported(.seconds)),
            (0x0019, "Osmo Nano", expected(gimbal: false, zoom: false, focus: false, iris: false, timecode: false, audio: true), .unsupported),
        ]
        for (id, name, layout, timecode) in bodies {
            let port = FakePort()
            port.connectedModel = CameraModel.resolve(modelId: id, name: name)
            let seam = DJICameraSessionAdapter(session: port)
            #expect(seam.layout(base: base) == layout, "\(name)")
            #expect(seam.current.capabilities.timecodeCapability == timecode, "\(name)")
            #expect(seam.current.capabilities.audioLevels == .supported, "\(name)")
            #expect((port.connectedModel?.motion != nil) == layout.gimbal, "\(name)")
        }
        // No camera: nothing is claimed, so the layout is the base.
        let port = FakePort()
        port.connectedModel = nil
        let seam = DJICameraSessionAdapter(session: port)
        #expect(seam.layout(base: base) == base)
        #expect(seam.current.capabilities.timecodeCapability == .unknown)
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
        port.status.timecodeValue = CameraTimecode(hours: 5, minutes: 22, seconds: 47, frames: 18)
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
        port.status.timecodeValue = nil
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

    /// A5-09: the recording rate is a typed read-only Rational from the wire index, never written.
    @Test func recordingFrameRateIsAReadOnlyRational() {
        let port = Self.capturePort()
        let seam = DJICameraSessionAdapter(session: port)
        #expect(seam.current.capabilities[.frameRate]?.access == .readOnly)
        #expect(seam.current.value(of: .frameRate).value == nil, "no report is unknown")
        port.captureControlState?.reported.fps = 25
        #expect(seam.current.value(of: .frameRate).value == .frameRate(Rational(25)))
        #expect(seam.request(.set(.frameRate(Rational(24)))).stage == .rejected(.readOnly))
        #expect(port.fired.isEmpty)
    }

    /// Behavior audit PAA-210 / PIA-211: Pocket 3 publishes no `camcap_shutter`. The standalone
    /// apps offered the documented video ladder (with the live 1/N merged in) and sent any of it.
    @Test func emptyShutterCapOffersTheDocumentedLadderAndWrites() {
        let port = Self.capturePort()
        port.captureControlState?.reported.availableShutterDenoms = []
        port.captureControlState?.reported.shootingMode = Int(ShootingMode.video.rawValue)
        port.captureControlState?.reported.fps = 25
        let seam = DJICameraSessionAdapter(session: port)
        let shutter = seam.current.capabilities[.shutter]
        #expect(shutter?.access == .readWrite)
        #expect(shutter?.domain?.choices == CamCapShutter.wheelDenoms(available: [], current: 50).map {
            SettingValue.shutter(.duration(Rational(1, $0)))
        })
        #expect(port.captureControlState?.admitsShutterWrite(100) == true)
        #expect(seam.request(.set(.shutter(.duration(Rational(1, 100))))).stage == .admitted)
        #expect(port.fired == ["shutter 100"])
        // The Angle preference maps onto the same ladder (180 degrees at 25p is 1/50).
        port.captureControlState?.shutterPresentation = .emulatedAngle
        #expect(DJICameraSessionAdapter(session: port).request(.set(.shutter(.angle(180)))).stage == .admitted)
        #expect(port.fired.last == "angle 180.0 1/50")
    }

    /// The Pocket path pins the same rule as the Luna: the wire carries whole 1/N, 180 degrees
    /// sends the ladder's nearest speed per rate and the projected angle is what it really makes.
    @Test func angleSendsTheNearestLadderSpeedPerRate() throws {
        for (fps, denom) in [(24, 48), (25, 50), (30, 60), (60, 120), (120, 250)] {
            let port = Self.capturePort()
            port.captureControlState?.reported.availableShutterDenoms = []
            port.captureControlState?.reported.shootingMode = Int(ShootingMode.video.rawValue)
            port.captureControlState?.reported.fps = fps
            port.captureControlState?.shutterPresentation = .emulatedAngle
            let seam = DJICameraSessionAdapter(session: port)
            #expect(seam.request(.set(.shutter(.angle(180)))).stage == .admitted, "\(fps) fps")
            #expect(port.fired.last == "angle 180.0 1/\(denom)", "\(fps) fps")
            port.captureControlState?.reported.shutterDenom = denom
            let shown = DJICameraSessionAdapter(session: port).current.value(of: .shutter).value
            guard case .shutter(.angle(let angle))? = shown else { Issue.record("\(fps) fps"); continue }
            #expect(abs(angle - 360 * Double(fps) / Double(denom)) < 1e-9, "\(fps) fps")
        }
    }

    /// Behavior audit PAA-211: the Angle preference is a video presentation. In Photo the
    /// standalone apps forced the Speed tab and a 1/N readout, so the common shutter stays a duration.
    @Test func photoModeKeepsShutterDurationsUnderTheAnglePreference() {
        let port = Self.capturePort()
        port.captureControlState?.shutterPresentation = .emulatedAngle
        port.captureControlState?.reported.shootingMode = Int(ShootingMode.photoRawPocket3AndNano)
        port.captureControlState?.reported.fps = 25
        let seam = DJICameraSessionAdapter(session: port)
        let shutter = seam.current.capabilities[.shutter]
        #expect(shutter?.availability == .available)
        #expect(shutter?.domain?.choices == [50, 100].map { SettingValue.shutter(.duration(Rational(1, $0))) })
        #expect(seam.current.value(of: .shutter).value == .shutter(.duration(Rational(1, 50))))
        #expect(seam.request(.set(.shutter(.duration(Rational(1, 100))))).stage == .admitted)
        #expect(port.fired == ["shutter 100"])
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
final class FakePort: DJIControlPort {
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
    func writeHostShutterAngle(
        _ degrees: Double, denominator: Int, admission: DJICommandAdmission?,
        onStage: @escaping @MainActor (ControlWireEvent) -> Void
    ) {
        fire("angle \(degrees) 1/\(denominator)", onStage)
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
