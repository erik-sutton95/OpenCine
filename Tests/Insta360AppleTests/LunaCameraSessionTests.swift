import Insta360Apple
import Insta360AppleTestSupport
import Insta360Protocol
import OpenCineCore
import OpenCineMotion
import XCTest

@MainActor
final class LunaCameraSessionTests: XCTestCase {
    private func submit(
        _ intent: CameraCommandIntent, to session: LunaCameraSession
    ) async -> (submitted: CommandReceipt, outcome: CommandReceipt) {
        let command = CameraCommand(intent, preconditions: CommandPreconditions(session.current))
        let submitted = await session.submit(command)
        let outcome = await session.outcome(of: command.operation) ?? submitted
        return (submitted, outcome)
    }

    /// The old hole: `LunaCameraBackend` advertised recording, exposure and white balance but
    /// never implemented `apply`. Every writable capability the session describes must reach
    /// the camera and confirm; a descriptor without an implementation fails here.
    func testEveryAdvertisedWritableCapabilityReachesTheCamera() async {
        let camera = FakeLuna()
        let session = camera.connectedSession()
        let described = session.current.capabilities.descriptors.values.filter {
            $0.access == .readWrite
        }
        XCTAssertTrue(
            Set(described.map(\.key)).isSuperset(of: [.iso, .shutter, .whiteBalance, .recording]),
            "the CORE-02 slice must be advertised")
        for descriptor in described {
            XCTAssertEqual(descriptor.availability, .available, "\(descriptor.key)")
            let intent: CameraCommandIntent
            if descriptor.key == .recording {
                intent = .startRecording
            } else {
                let reported = session.current.value(of: descriptor.key).value
                guard let value = descriptor.domain?.choices.last(where: { $0 != reported }) else {
                    XCTFail("\(descriptor.key) has no value to write")
                    continue
                }
                intent = .set(value)
            }
            let before = camera.sent.count
            let (_, outcome) = await submit(intent, to: session)
            XCTAssertEqual(outcome.stage, .confirmed, "\(descriptor.key): \(outcome.stage)")
            XCTAssertEqual(camera.sent.count, before + 1, "\(descriptor.key) never reached the camera")
        }
    }

    func testAcceptedWriteThatDoesNotStickIsNotApplied() async {
        let camera = FakeLuna()
        let session = camera.connectedSession(settle: .milliseconds(600))
        camera.ignoresWrites = true
        let (submitted, outcome) = await submit(.set(.iso(.manual(800))), to: session)
        XCTAssertEqual(submitted.stage, .awaitingObservation, "acknowledged is not confirmed")
        XCTAssertEqual(outcome.stage, .failed(.notApplied))
        XCTAssertEqual(session.current.value(of: .iso).value, .iso(.auto), "reported stays reported")
    }

    func testSlowSettleStaysPendingAndConfirmsFromReadback() async {
        let camera = FakeLuna()
        let session = camera.connectedSession()
        camera.applyDelay = .milliseconds(300)
        let command = CameraCommand(
            .set(.whiteBalance(.kelvin(3200))), preconditions: CommandPreconditions(session.current))
        let submitted = await session.submit(command)
        XCTAssertEqual(submitted.stage, .awaitingObservation)
        XCTAssertEqual(
            session.current.value(of: .whiteBalance).value, .whiteBalance(.kelvin(5600)),
            "a request is never written into the reported snapshot")
        let outcome = await session.outcome(of: command.operation)
        XCTAssertEqual(outcome?.stage, .confirmed)
        XCTAssertEqual(session.current.value(of: .whiteBalance).value, .whiteBalance(.kelvin(3200)))
        XCTAssertEqual(session.current.value(of: .whiteBalance).origin, .cameraReported)
    }

    func testNoReadbackTimesOut() async {
        let camera = FakeLuna()
        let session = camera.connectedSession(settle: .milliseconds(600))
        camera.silent = true
        let (_, outcome) = await submit(.set(.whiteBalance(.auto)), to: session)
        XCTAssertEqual(outcome.stage, .timedOut)
    }

    /// A 500 reply (`LunaCameraBackend.send` throws `cameraRejectedRequest`) is a refusal.
    func testCameraRefusalIsARejection() async {
        let refusing = LunaCameraSession(
            send: { _ in throw LunaProtocolError.cameraRejectedRequest },
            functionMode: { LunaFunctionMode.normalVideo.rawValue }, readSettings: {},
            readCapture: {})
        refusing.linkChanged(.streaming, serial: nil)
        let (_, outcome) = await submit(.set(.whiteBalance(.auto)), to: refusing)
        XCTAssertEqual(outcome.stage, .rejected(.cameraRefused))
        XCTAssertEqual(refusing.current.connection, .ready, "a refusal is not a lost link")
    }

    /// MULTI-03 F6 and F1: the fixed lens is declared unsupported (shared UI can tell "no iris"
    /// from "not discovered"); observations are stamped on the shared host clock.
    func testFixedApertureIsUnsupportedAndReportsUseTheSharedClock() {
        let session = FakeLuna().connectedSession()
        XCTAssertEqual(session.current.capabilities.support(of: .aperture), .unsupported)
        XCTAssertEqual(session.current.capabilities.support(of: .zoom), .unknown)
        let stamped = session.current.value(of: .iso).observedAt
        let now = MonotonicInstant.now()
        XCTAssertTrue(stamped.map { $0 <= now && now - $0 < .seconds(5) } == true, "\(stamped as Any)")
    }

    /// SHELL-01: Luna publishes its gimbal with camera-reported pose, host-derived timecode and no
    /// audio levels, so the projection lays out the stick, head tracking and timecode, never a meter.
    func testPublishesMotionTimecodeAndNoAudio() {
        let session = FakeLuna().connectedSession()
        let capabilities = session.current.capabilities
        XCTAssertEqual(capabilities.timecode, .supported)
        XCTAssertEqual(capabilities.audioLevels, .unsupported)
        XCTAssertEqual(LunaCameraSession.motion.pose, .supported)
        XCTAssertFalse(LunaCameraSession.motion.axes.contains(.zoom), "moves keep one zoom")
        var base = MonitorLayoutCapabilities()
        base.audio = true
        let layout = MonitorLayoutCapabilities(capabilities, motion: LunaCameraSession.motion, base: base)
        XCTAssertTrue(layout.gimbal)
        XCTAssertTrue(layout.headTracking)
        XCTAssertTrue(layout.timecode)
        XCTAssertFalse(layout.audio, "unsupported overrides the base")
        XCTAssertFalse(layout.iris, "fixed aperture")
        // The session's own layout adds zoom and focus, which the app drives outside the session.
        var expected = layout
        (expected.zoom, expected.focus) = (true, true)
        XCTAssertEqual(session.layout(base: base), expected)

        XCTAssertNil(session.current.timecode.value, "nothing derived yet: unknown")
        session.ingest(timecode: CameraTimecode(hours: 15, minutes: 39, seconds: 50, frames: 12))
        XCTAssertEqual(session.current.timecode.value?.seconds, 50)
        XCTAssertEqual(session.current.timecode.origin, .clockDerived, "never a camera counter")
    }

    func testUnknownStaysUnknown() {
        let camera = FakeLuna()
        camera.captureState = nil
        let session = camera.makeSession()
        session.linkChanged(.streaming, serial: nil)
        camera.reportDevice()
        XCTAssertNil(session.current.recording.value, "no capture report: unknown, not idle")
        XCTAssertNil(session.current.power.battery.value, "no battery report: unknown, not empty")
        XCTAssertNil(session.current.storage.value, "no storage report: unknown, not none")
        XCTAssertNil(session.current.device, "no serial: no invented identity")
        XCTAssertNil(session.current.value(of: .iso).value)
        // A photo capture state says nothing about video recording.
        camera.captureState = 4
        camera.reportCapture()
        XCTAssertNil(session.current.recording.value)
        camera.captureState = 1
        camera.reportCapture()
        XCTAssertEqual(session.current.recording.value, .recording)
        XCTAssertEqual(session.current.recording.origin, .cameraReported)
        camera.captureState = 4
        camera.reportCapture()
        XCTAssertNil(session.current.recording.value, "an unreadable state does not keep a stale one")
    }

    func testRecordingIsUnavailableUntilTheModeIsKnownAndISOUntilExposureIsKnown() async {
        let camera = FakeLuna()
        let session = camera.makeSession()
        session.linkChanged(.streaming, serial: nil)
        let (_, record) = await submit(.startRecording, to: session)
        XCTAssertEqual(record.stage, .rejected(.unavailable(.notReady)))
        let (_, iso) = await submit(.set(.iso(.manual(400))), to: session)
        XCTAssertEqual(iso.stage, .rejected(.unavailable(.notReady)))
    }

    func testExplicitStartWhileRecordingSendsNothing() async {
        let camera = FakeLuna()
        camera.captureState = 1
        let session = camera.connectedSession()
        let (_, start) = await submit(.startRecording, to: session)
        XCTAssertEqual(start.stage, .confirmed)
        XCTAssertTrue(camera.sent.isEmpty, "a start while recording must not reach the camera")
        camera.captureState = 0
        camera.reportCapture()
        let (_, stop) = await submit(.stopRecording, to: session)
        XCTAssertEqual(stop.stage, .confirmed)
        XCTAssertTrue(camera.sent.isEmpty, "a stop while idle must not reach the camera")
    }

    func testRecordingIsReportedOnlyByTheCamera() async {
        let camera = FakeLuna()
        let session = camera.connectedSession()
        camera.applyDelay = .milliseconds(150)
        let command = CameraCommand(.startRecording, preconditions: CommandPreconditions(session.current))
        let submitted = await session.submit(command)
        XCTAssertEqual(submitted.stage, .awaitingObservation)
        XCTAssertEqual(session.current.recording.value, .idle, "ACK is not a recording report")
        let outcome = await session.outcome(of: command.operation)
        XCTAssertEqual(outcome?.stage, .confirmed)
        XCTAssertEqual(session.current.recording.value, .recording)
        XCTAssertEqual(camera.sent.map(\.command), [.startCapture])
    }

    /// ISO and shutter share one Luna message: an ISO write keeps a still-pending shutter.
    func testExposureWriteCarriesThePendingShutter() async throws {
        let camera = FakeLuna()
        let session = camera.connectedSession()
        camera.applyDelay = .milliseconds(200)
        let shutter = CameraCommand(
            .set(.shutter(.duration(Rational(1, 100)))),
            preconditions: CommandPreconditions(session.current))
        _ = await session.submit(shutter)
        let iso = CameraCommand(
            .set(.iso(.manual(400))), preconditions: CommandPreconditions(session.current))
        _ = await session.submit(iso)
        let sent = try LunaPhotographySettings(response: try XCTUnwrap(camera.sent.last).body)
        XCTAssertEqual(sent.videoExposure?.exposureProgram, .manual)
        XCTAssertEqual(sent.videoExposure?.iso, 400)
        XCTAssertEqual(sent.videoExposure?.shutterSeconds ?? 0, 0.01, accuracy: 1e-9)
        let shutterOutcome = await session.outcome(of: shutter.operation)
        let isoOutcome = await session.outcome(of: iso.operation)
        XCTAssertEqual(shutterOutcome?.stage, .confirmed)
        XCTAssertEqual(isoOutcome?.stage, .confirmed)
        XCTAssertEqual(session.current.value(of: .shutter).value, .shutter(.duration(Rational(1, 100))))
    }

    func testRecordingProfileIsCameraReportedOrUnknown() {
        let camera = FakeLuna()
        let session = camera.connectedSession()
        XCTAssertNil(session.recordingProfile.value)
        camera.colorMode = LunaColorMode.iLog.rawValue
        camera.reportSettings()
        XCTAssertEqual(session.recordingProfile.value, "com.opencapture.insta360.luna.profile.i-log")
        XCTAssertEqual(session.recordingProfile.origin, .cameraReported)
        XCTAssertEqual(session.current.mode.value?.role, .video)
    }

    func testANewerWriteToTheSameSettingSupersedesTheOlder() async {
        let camera = FakeLuna()
        let session = camera.connectedSession(settle: .seconds(5))
        camera.applyDelay = .seconds(10)
        let older = await session.submit(
            CameraCommand(.set(.iso(.manual(400))), preconditions: CommandPreconditions(session.current)))
        XCTAssertEqual(session.receipt(of: older.operation)?.stage, .awaitingObservation)
        _ = await session.submit(
            CameraCommand(.set(.iso(.manual(1600))), preconditions: CommandPreconditions(session.current)))
        XCTAssertEqual(session.receipt(of: older.operation)?.stage, .failed(.superseded))
        session.close(.requested)
    }

    func testLinkLossEndsInFlightWritesAsUnknownAndANewLinkIsANewEpoch() async {
        let camera = FakeLuna()
        let session = camera.connectedSession(settle: .seconds(5))
        camera.applyDelay = .seconds(10)
        let epoch = session.current.epoch
        let command = CameraCommand(
            .set(.iso(.manual(1600))), preconditions: CommandPreconditions(session.current))
        _ = await session.submit(command)
        session.linkChanged(.idle, serial: nil)
        let outcome = await session.outcome(of: command.operation)
        XCTAssertEqual(outcome?.stage, .outcomeUnknown)
        guard case .recovering = session.current.connection else {
            return XCTFail("expected recovering, got \(session.current.connection)")
        }
        session.linkChanged(.streaming, serial: nil)
        XCTAssertEqual(session.current.epoch, epoch.next())
        let late = await session.submit(
            CameraCommand(
                .set(.iso(.manual(200))),
                preconditions: CommandPreconditions(
                    session: session.id, epoch: epoch,
                    capabilityRevision: session.current.capabilities.revision)))
        XCTAssertEqual(late.stage, .rejected(.staleEpoch), "an edit from the old link is refused")
    }

    func testCloseFinishesFeedsAndNeverSends() async {
        let camera = FakeLuna()
        let session = camera.connectedSession()
        let feed = session.snapshots()
        session.close(.requested)
        session.close(.requested)
        var last: CameraSnapshot?
        for await snapshot in feed { last = snapshot }
        XCTAssertEqual(last?.connection, .disconnected(.requested))
        let (_, after) = await submit(.startRecording, to: session)
        XCTAssertEqual(after.stage, .rejected(.sessionClosed))
        XCTAssertTrue(camera.sent.isEmpty)
    }
}

/// The app's record lamp through the Core seam: explicit start/stop from a fresh report.
