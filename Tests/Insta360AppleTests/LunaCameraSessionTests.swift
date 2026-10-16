import Insta360Apple
import Insta360AppleTestSupport
import Insta360Protocol
import OpenCineCore
import OpenCineMedia
import OpenCineMotion
import XCTest

@MainActor
final class LunaCameraSessionTests: XCTestCase {
    private func reportCadence(_ raw: UInt64?, to session: LunaCameraSession) throws {
        let nested = try raw.map { try ProtoMessage.integer(field: 31, value: $0) } ?? Data()
        let body = try ProtoMessage.blob(field: 1, value: ProtoMessage.varint(31))
            + ProtoMessage.blob(field: 2, value: nested)
            + ProtoMessage.integer(field: 3, value: UInt64(LunaFunctionMode.normalVideo.rawValue))
        session.ingest(settings: try LunaPhotographySettings(response: body))
    }

    func testEmulatedAngleConfirmsTheQuantizedNativeReadback() async throws {
        let camera = FakeLuna()
        camera.program = LunaExposureProgram.manual.rawValue
        camera.iso = 400
        camera.shutterSeconds = 1.0 / 50
        let session = camera.connectedSession(now: { MonotonicInstant(.zero) })
        try reportCadence(48, to: session)
        session.configureShutter(presentation: .emulatedAngle)
        XCTAssertEqual(session.current.capabilities[.shutter]?.semantics.implementation, .emulated)
        XCTAssertEqual(session.current.value(of: .shutter).value, .shutter(.angle(180)))
        let (_, outcome) = await submit(.set(.shutter(.angle(144))), to: session)
        XCTAssertEqual(outcome.stage, .confirmed)
        let request = try XCTUnwrap(camera.sent.last)
        let exposure = try XCTUnwrap(LunaPhotographySettings(response: request.body).videoExposure)
        XCTAssertEqual(exposure.shutterSeconds, 1.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(session.current.value(of: .shutter).value, .shutter(.angle(150)))
        XCTAssertEqual(session.current.value(of: .shutter).origin, .protocolDerived)
    }

    func testAngleEmulationNeedsReportedCadenceAndPreservesNativeIsoComposition() async throws {
        let camera = FakeLuna()
        camera.program = LunaExposureProgram.manual.rawValue
        camera.iso = 400
        camera.shutterSeconds = 1.0 / 50
        let session = camera.connectedSession(now: { MonotonicInstant(.zero) })
        session.configureShutter(presentation: .emulatedAngle)
        XCTAssertNil(session.current.value(of: .shutter).value)
        let rejected = await session.submit(CameraCommand(.set(.shutter(.angle(180))),
            preconditions: CommandPreconditions(session.current)))
        guard case .rejected = rejected.stage else { return XCTFail("unknown cadence admitted an angle write") }
        XCTAssertTrue(camera.sent.isEmpty)
        let (_, outcome) = await submit(.set(.iso(.manual(800))), to: session)
        XCTAssertEqual(outcome.stage, .confirmed)
        let request = try XCTUnwrap(camera.sent.last)
        let exposure = try XCTUnwrap(LunaPhotographySettings(response: request.body).videoExposure)
        XCTAssertEqual(exposure.iso, 800)
        XCTAssertEqual(exposure.shutterSeconds, 1.0 / 50, accuracy: 1e-9)
        session.configureShutter(presentation: .cameraValue)
        XCTAssertEqual(session.current.value(of: .shutter).value, .shutter(.duration(Rational(1, 50))))
        XCTAssertEqual(session.current.value(of: .shutter).origin, .cameraReported)
    }

    func testCadenceChangeRetiresPreparedAngleCommands() async throws {
        let camera = FakeLuna()
        camera.program = LunaExposureProgram.manual.rawValue
        camera.iso = 400
        camera.shutterSeconds = 1.0 / 50
        let session = camera.connectedSession(now: { MonotonicInstant(.zero) })
        try reportCadence(48, to: session)
        session.configureShutter(presentation: .emulatedAngle)
        let command = CameraCommand(.set(.shutter(.angle(180))), preconditions: CommandPreconditions(session.current))
        try reportCadence(24, to: session)
        let receipt = await session.submit(command)
        XCTAssertEqual(receipt.stage, .rejected(.staleCapabilities))
        XCTAssertTrue(camera.sent.isEmpty)
        try reportCadence(nil, to: session)
        XCTAssertNil(session.current.value(of: .shutter).value)
    }

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
        session.configureLens(zoomDomain: 1...4)
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
            } else if descriptor.key == .zoom, let range = descriptor.domain?.range {
                intent = .set(.zoom(range.upperBound))
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
            XCTAssertEqual(
                camera.sent.count, before + 1, "\(descriptor.key) never reached the camera")
        }
    }

    /// Requests outside the common model go out only while the session is ready and owned, with
    /// the caller's timeout when the backend takes one.
    func testControlRequestsNeedAReadyOwnedSessionAndKeepTheirTimeout() async throws {
        var plain: [LunaRequest] = []
        var timed: [(LunaRequest, Duration)] = []
        let session = LunaCameraSession(
            send: { plain.append($0); return Data() },
            sendWithin: { timed.append(($0, $1)); return Data() },
            functionMode: { LunaFunctionMode.normalVideo.rawValue },
            readSettings: {}, readCapture: {})
        let request = LunaProtocol.cancelTrackingRequest
        XCTAssertFalse(session.admitsControl)
        do {
            _ = try await session.control(request)
            XCTFail("a connecting session must not send")
        } catch {}
        session.linkChanged(.streaming, serial: "LUNA-TEST")
        _ = try await session.control(request)
        _ = try await session.control(request, timeout: .seconds(2))
        XCTAssertEqual(plain, [request])
        XCTAssertEqual(timed.map(\.0), [request])
        XCTAssertEqual(timed.map(\.1), [.seconds(2)])
        session.close(.requested)
        do {
            _ = try await session.control(request)
            XCTFail("a closed session must not send")
        } catch {}
        XCTAssertEqual(plain.count + timed.count, 2)
    }

    /// The official app's clock SET, then cmd 214 twice, each stamped at send; nothing more when
    /// the camera refuses the SET.
    func testClockSyncSetsTheClockThenSyncsToTheMillisecondTwice() async throws {
        var sent: [(LunaRequest, Duration)] = []
        var refuses = false
        let session = LunaCameraSession(
            send: { _ in Data() },
            sendWithin: {
                sent.append(($0, $1))
                if refuses { throw CancellationError() }
                return Data()
            },
            functionMode: { LunaFunctionMode.normalVideo.rawValue },
            readSettings: {}, readCapture: {})
        // 2026-09-30 08:51:10.54 UTC, Stockholm (UTC+2).
        let zone = try XCTUnwrap(TimeZone(identifier: "Europe/Stockholm"))
        var stamps: [Double] = []
        let now = { Date(timeIntervalSince1970: stamps.removeFirst()) }
        stamps = [1_790_758_270.54]
        let connecting = await session.syncClock(zone: zone, now: now)
        XCTAssertFalse(connecting)
        XCTAssertTrue(sent.isEmpty)

        session.linkChanged(.streaming, serial: "LUNA-TEST")
        stamps = [1_790_758_270.54, 1_790_758_270.761, 1_790_758_270.765]
        let synced = await session.syncClock(zone: zone, now: now)
        XCTAssertTrue(synced)
        XCTAssertEqual(
            sent.map(\.0),
            [
                try LunaProtocol.setClockRequest(
                    unixSeconds: 1_790_758_270, timeZoneSeconds: 7200, zone: "Europe/Stockholm"),
                try LunaProtocol.syncTimeAccurateRequest(
                    unixMilliseconds: 1_790_758_270_761, count: 0),
                try LunaProtocol.syncTimeAccurateRequest(
                    unixMilliseconds: 1_790_758_270_765, count: 1),
            ])
        XCTAssertEqual(sent.map(\.1), [.seconds(2), .seconds(2), .seconds(2)])

        sent = []
        refuses = true
        stamps = [1_790_758_280.0]
        let refused = await session.syncClock(zone: zone, now: now)
        XCTAssertFalse(refused)
        XCTAssertEqual(sent.count, 1)
    }

    func testAcceptedWriteThatDoesNotStickIsNotApplied() async {
        let camera = FakeLuna()
        let session = camera.connectedSession(settle: .milliseconds(600))
        camera.ignoresWrites = true
        let (submitted, outcome) = await submit(.set(.iso(.manual(800))), to: session)
        XCTAssertEqual(submitted.stage, .awaitingObservation, "acknowledged is not confirmed")
        XCTAssertEqual(outcome.stage, .failed(.notApplied))
        XCTAssertEqual(
            session.current.value(of: .iso).value, .iso(.auto), "reported stays reported")
    }

    func testSlowSettleStaysPendingAndConfirmsFromReadback() async {
        let camera = FakeLuna()
        let session = camera.connectedSession()
        camera.applyDelay = .milliseconds(300)
        let command = CameraCommand(
            .set(.whiteBalance(.kelvin(3200))), preconditions: CommandPreconditions(session.current)
        )
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
        XCTAssertTrue(
            stamped.map { $0 <= now && now - $0 < .seconds(5) } == true, "\(stamped as Any)")
    }

    /// SHELL-01: Luna publishes its gimbal with camera-reported pose, host-derived timecode and no
    /// audio levels, so the projection lays out the stick, head tracking and timecode, never a meter.
    func testPublishesMotionTimecodeAndNoAudio() {
        let session = FakeLuna().connectedSession()
        let capabilities = session.current.capabilities
        XCTAssertEqual(capabilities.timecodeCapability, .supported(.seconds), "host clock: whole seconds")
        XCTAssertEqual(capabilities.audioLevels, .unsupported)
        XCTAssertEqual(LunaCameraSession.motion.pose, .supported)
        XCTAssertFalse(LunaCameraSession.motion.axes.contains(.zoom), "moves keep one zoom")
        var base = MonitorLayoutCapabilities()
        base.audio = true
        let layout = MonitorLayoutCapabilities(
            capabilities, motion: LunaCameraSession.motion, base: base)
        XCTAssertTrue(layout.gimbal)
        XCTAssertTrue(layout.headTracking)
        XCTAssertTrue(layout.timecode)
        XCTAssertFalse(layout.audio, "unsupported overrides the base")
        XCTAssertFalse(layout.iris, "fixed aperture")
        // The session lays out the one control model: Luna declares its zoom stops, so the zoom
        // chip shows before the live zoom range arrives.
        var modelLayout = layout
        modelLayout.zoom = true
        XCTAssertEqual(session.layout(base: base), modelLayout)

        XCTAssertNil(session.current.timecode.value, "nothing derived yet: unknown")
        session.ingest(timecode: CameraTimecodeReading(hours: 15, minutes: 39, seconds: 50))
        XCTAssertEqual(session.current.timecodeReading.value?.seconds, 50)
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
        XCTAssertNil(
            session.current.recording.value, "an unreadable state does not keep a stale one")
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
        let command = CameraCommand(
            .startRecording, preconditions: CommandPreconditions(session.current))
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
        XCTAssertEqual(
            session.current.value(of: .shutter).value, .shutter(.duration(Rational(1, 100))))
    }

    func testRecordingProfileIsCameraReportedOrUnknown() {
        let camera = FakeLuna()
        let session = camera.connectedSession()
        XCTAssertNil(session.recordingProfile.value)
        camera.colorMode = LunaColorMode.iLog.rawValue
        camera.reportSettings()
        XCTAssertEqual(
            session.recordingProfile.value, "com.opencapture.insta360.luna.profile.i-log")
        XCTAssertEqual(session.recordingProfile.origin, .cameraReported)
        XCTAssertEqual(session.current.mode.value?.role, .video)
    }

    func testANewerWriteToTheSameSettingSupersedesTheOlder() async {
        let camera = FakeLuna()
        let session = camera.connectedSession(settle: .seconds(5))
        camera.applyDelay = .seconds(10)
        let older = await session.submit(
            CameraCommand(
                .set(.iso(.manual(400))), preconditions: CommandPreconditions(session.current)))
        XCTAssertEqual(session.receipt(of: older.operation)?.stage, .awaitingObservation)
        _ = await session.submit(
            CameraCommand(
                .set(.iso(.manual(1600))), preconditions: CommandPreconditions(session.current)))
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
