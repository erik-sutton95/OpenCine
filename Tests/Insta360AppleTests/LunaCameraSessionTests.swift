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

    /// II-061/069/070, IA-115..119: angle is a presentation. The host still writes the camera's own
    /// durations (an angle pick, Manual from Auto, AE-L) and Auto, and the first manual shutter may
    /// leave Auto, as before the shared session.
    func testEmulatedAngleStillAdmitsNativeDurationsAutoAndLeavingAuto() async throws {
        let camera = FakeLuna()
        camera.program = LunaExposureProgram.automatic.rawValue
        camera.iso = 400
        camera.shutterSeconds = 1.0 / 50
        let session = camera.connectedSession(now: { MonotonicInstant(.zero) })
        try reportCadence(48, to: session)
        session.configureShutter(presentation: .emulatedAngle)
        XCTAssertEqual(session.current.capabilities[.shutter]?.availability, .available)
        let (_, manual) = await submit(.set(.shutter(.duration(Rational(1, 50)))), to: session)
        XCTAssertEqual(manual.stage, .confirmed, "Manual from Auto in angle mode")
        var exposure = try XCTUnwrap(LunaPhotographySettings(response: try XCTUnwrap(camera.sent.last).body).videoExposure)
        XCTAssertEqual(exposure.shutterSeconds, 1.0 / 50, accuracy: 1e-9)
        let (_, faster) = await submit(.set(.shutter(.duration(Rational(1, 100)))), to: session)
        XCTAssertEqual(faster.stage, .confirmed, "an angle pick sent as its 1/N")
        let (_, auto) = await submit(.set(.shutter(.auto)), to: session)
        XCTAssertEqual(auto.stage, .confirmed, "Auto exposure from angle mode")
        let (_, angle) = await submit(.set(.shutter(.angle(180))), to: session)
        XCTAssertEqual(angle.stage, .confirmed, "an angle from Auto composes 1/N from the cadence")
        exposure = try XCTUnwrap(LunaPhotographySettings(response: try XCTUnwrap(camera.sent.last).body).videoExposure)
        XCTAssertEqual(exposure.shutterSeconds, 1.0 / 50, accuracy: 1e-9)
    }

    /// Owner 2026-10-20, Luna Ultra 8K30, shutter priority, Angle 180: SHUTTER read "0.0108°".
    /// The camera's single-precision readback of 1/60 is not bit-exact, became 16667/1000000 and
    /// its denominator alone made 360 x 30 / 1e6 degrees.
    func testAnInexactReadbackIsTheSpeedAndItsAngle() async throws {
        let camera = FakeLuna()
        camera.reportsSinglePrecisionShutter = true
        camera.program = LunaExposureProgram.shutterPriority.rawValue
        camera.shutterSeconds = 1.0 / 60
        let session = camera.connectedSession(now: { MonotonicInstant(.zero) })
        try reportCadence(LunaVideoResolution.rawValue(width: 3840, height: 2160, framesPerSecond: 30), to: session)
        XCTAssertEqual(session.current.value(of: .shutter).value, .shutter(.duration(Rational(1, 60))))
        session.configureShutter(presentation: .emulatedAngle)
        XCTAssertEqual(session.current.value(of: .shutter).value, .shutter(.angle(180)))
    }

    /// 180 degrees sends the Luna wheel's nearest 1/N at each rate, confirms against an inexact
    /// readback and reads back the angle the camera really makes.
    func testAngleSendsTheNearestWheelSpeedPerRate() async throws {
        let cases: [(fps: Double, denom: Int)] = [(24, 50), (25, 50), (30, 60), (60, 125), (120, 250)]
        for (fps, denom) in cases {
            let camera = FakeLuna()
            camera.reportsSinglePrecisionShutter = true
            camera.program = LunaExposureProgram.manual.rawValue
            camera.iso = 400
            camera.shutterSeconds = 1.0 / 1000
            let session = camera.connectedSession(now: { MonotonicInstant(.zero) })
            try reportCadence(LunaVideoResolution.rawValue(width: 3840, height: 2160, framesPerSecond: fps), to: session)
            session.configureShutter(presentation: .emulatedAngle)
            let (_, outcome) = await submit(.set(.shutter(.angle(180))), to: session)
            XCTAssertEqual(outcome.stage, .confirmed, "\(fps) fps")
            let exposure = try XCTUnwrap(LunaPhotographySettings(response: try XCTUnwrap(camera.sent.last).body).videoExposure)
            XCTAssertEqual(exposure.shutterSeconds, 1.0 / Double(denom), accuracy: 1e-12, "\(fps) fps")
            guard case .shutter(.angle(let angle))? = session.current.value(of: .shutter).value else {
                return XCTFail("\(fps) fps has no angle")
            }
            XCTAssertEqual(angle, 360 * fps / Double(denom), accuracy: 1e-9, "\(fps) fps")
        }
    }

    private func reportPhotoMode(to session: LunaCameraSession) throws {
        let nested = try ProtoMessage.integer(field: 40, value: 0) + ProtoMessage.integer(field: 41, value: 100)
        session.ingest(device: try LunaDeviceStatus(response: ProtoMessage.blob(field: 2, value: nested)))
    }

    private func offersAngles(_ session: LunaCameraSession) -> Bool {
        let choices = session.current.capabilities[.shutter]?.domain?.choices ?? []
        return choices.contains { if case .shutter(.angle) = $0 { true } else { false } }
    }

    /// CodeRabbit on #114: photo exposure never composes an angle, so angle mode in photo offers
    /// the camera's durations only.
    func testEmulatedAngleOffersNoAnglesInPhotoMode() async throws {
        let camera = FakeLuna()
        camera.program = LunaExposureProgram.manual.rawValue
        camera.iso = 400
        camera.shutterSeconds = 1.0 / 50
        let session = camera.connectedSession(now: { MonotonicInstant(.zero) })
        try reportCadence(48, to: session)
        session.configureShutter(presentation: .emulatedAngle)
        XCTAssertTrue(offersAngles(session), "video with a cadence offers angles")
        try reportPhotoMode(to: session)
        XCTAssertFalse(offersAngles(session), "photo mode offered an angle it cannot write")
        XCTAssertEqual(session.current.capabilities[.shutter]?.availability, .available)
    }

    /// CodeRabbit on #114: an unknown cadence withholds only the angles; the camera's durations
    /// stay writable, as in camera-value mode.
    func testUnknownCadenceWithholdsOnlyTheAngles() async throws {
        let camera = FakeLuna()
        camera.program = LunaExposureProgram.manual.rawValue
        camera.iso = 400
        camera.shutterSeconds = 1.0 / 50
        let session = camera.connectedSession(now: { MonotonicInstant(.zero) })
        session.configureShutter(presentation: .emulatedAngle)
        XCTAssertFalse(offersAngles(session), "an angle offered without a cadence to compose it")
        XCTAssertEqual(session.current.capabilities[.shutter]?.availability, .available)
        let (_, outcome) = await submit(.set(.shutter(.duration(Rational(1, 100)))), to: session)
        XCTAssertEqual(outcome.stage, .confirmed)
        let exposure = try XCTUnwrap(
            LunaPhotographySettings(response: try XCTUnwrap(camera.sent.last).body).videoExposure)
        XCTAssertEqual(exposure.shutterSeconds, 1.0 / 100, accuracy: 1e-9)
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

    /// Hardware pass 8.4 (Insta iOS + Luna Ultra): the storage tap had no recording time step.
    /// The camera reports remaining record time per card (photography option 99); each usable
    /// volume carries its own, camera reported. A full card keeps a known zero; a reply without
    /// option 99 (the settings poll) keeps the last report.
    func testRemainingRecordTimeReachesEachCardVolume() throws {
        let camera = FakeLuna()
        let session = camera.connectedSession()
        func card(state: UInt64, free: UInt64, total: UInt64, location: UInt64) throws -> Data {
            try ProtoMessage.integer(field: 1, value: state) + ProtoMessage.integer(field: 2, value: free)
                + ProtoMessage.integer(field: 3, value: total) + ProtoMessage.integer(field: 4, value: location)
        }
        let nested =
            try ProtoMessage.integer(field: 40, value: 100) + ProtoMessage.integer(field: 41, value: 0)
            + ProtoMessage.blob(field: 176, value: card(state: 0, free: 99_000_000_000, total: 125_000_000_000, location: 2))
            + ProtoMessage.blob(field: 176, value: card(state: 0, free: 1_000_000, total: 64_000_000_000, location: 3))
        session.ingest(device: try LunaDeviceStatus(response: ProtoMessage.blob(field: 2, value: nested)))
        XCTAssertNil(session.current.storage.recordingTimeLabel, "no option 99 yet: unknown")

        func remaining(_ entries: [(UInt64, UInt64)]) throws -> LunaPhotographySettings {
            let options = try entries.reduce(into: Data()) { data, entry in
                data += try ProtoMessage.blob(
                    field: 99,
                    value: ProtoMessage.integer(field: 1, value: entry.0) + ProtoMessage.integer(field: 2, value: entry.1))
            }
            return try LunaPhotographySettings(
                response: ProtoMessage.blob(field: 1, value: ProtoMessage.varint(99))
                    + ProtoMessage.blob(field: 2, value: options)
                    + ProtoMessage.integer(field: 3, value: UInt64(LunaFunctionMode.normalVideo.rawValue)))
        }
        session.ingest(settings: try remaining([(3001, 2), (0, 3)]))
        let volumes = try XCTUnwrap(session.current.storage.value)
        let inner = try XCTUnwrap(volumes.first { $0.id == "location-2" })
        let sd = try XCTUnwrap(volumes.first { $0.id == "location-3" })
        XCTAssertEqual(inner.remainingRecordingTime.value, .seconds(3001))
        XCTAssertEqual(inner.remainingRecordingTime.origin, .cameraReported)
        XCTAssertEqual(sd.remainingRecordingTime.value, .seconds(0), "a full card is a known zero")
        XCTAssertEqual(inner.freeBytes.value, 99_000_000_000, "the card readout is kept")
        XCTAssertEqual(session.current.storage.recordingTimeLabel, "50 Min")
        XCTAssertEqual(session.current.storage.storageReadout?.percent, "79%")
        // Hardware pass 8.4: the shared storage cycle now reaches the time on Insta too.
        let storage = session.current.storage
        XCTAssertEqual(
            StorageReadoutCycle.forms(storage, photo: false),
            ["99GB", "79%", "50 Min"])
        XCTAssertEqual(
            StorageReadoutCycle.forms(storage, photo: true),
            ["99GB", "79%"])

        // The settings poll does not carry option 99: the last report stands.
        camera.reportSettings()
        XCTAssertEqual(session.current.storage.recordingTimeLabel, "50 Min")
        // A fresh device report keeps the time for its card.
        session.ingest(device: try LunaDeviceStatus(response: ProtoMessage.blob(field: 2, value: nested)))
        XCTAssertEqual(session.current.storage.recordingTimeLabel, "50 Min")
        // A later option 99 without that card leaves it unknown.
        session.ingest(settings: try remaining([(0, 3)]))
        XCTAssertNil(session.current.storage.recordingTimeLabel)
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

    func testLinkChangesInvalidateTimecodeUntilTheReadySourcePublishesAgain() {
        for phase: CameraConnectionPhase in [.idle, .openingVideo] {
            let session = FakeLuna().connectedSession()
            let reading = CameraTimecodeReading(hours: 15, minutes: 39, seconds: 50)
            session.ingest(timecode: reading)
            XCTAssertEqual(session.current.timecodeReading.value, reading)
            session.linkChanged(.scanning, serial: nil)
            XCTAssertEqual(session.current.timecodeReading.value, reading, "scanning keeps the active source")

            session.linkChanged(phase, serial: nil)
            XCTAssertEqual(session.current.timecodeReading, .unknown, "\(phase) retires the clock")
            XCTAssertEqual(session.current.timecode, .unknown)
            session.ingest(timecode: reading)
            XCTAssertEqual(session.current.timecodeReading, .unknown, "late recovery frames stay retired")

            let epoch = session.current.epoch
            session.linkChanged(.streaming, serial: nil)
            XCTAssertEqual(session.current.epoch, epoch.next())
            XCTAssertNil(session.current.timecodeReading.value, "a new epoch waits for a fresh frame")
            session.ingest(timecode: reading)
            XCTAssertEqual(session.current.timecodeReading.value, reading)
            XCTAssertEqual(session.current.timecodeReading.origin, .clockDerived)
            XCTAssertNil(session.current.timecode.value, "whole seconds never invent frames")
            session.linkChanged(.streaming, serial: nil)
            XCTAssertEqual(session.current.timecodeReading, .unknown, "another LIVE is another epoch")
            session.close(.requested)
            session.ingest(timecode: reading)
            XCTAssertNil(session.current.timecodeReading.value)
        }
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
