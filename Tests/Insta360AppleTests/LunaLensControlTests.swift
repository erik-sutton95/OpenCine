import Foundation
import Insta360Apple
import Insta360Protocol
import OpenCineCore
import XCTest

private final class LensClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = MonotonicInstant.zero
    func read() -> MonotonicInstant { lock.withLock { instant } }
    func advance(_ duration: Duration) { lock.withLock { instant = instant + duration } }
}

@MainActor
final class LunaLensControlTests: XCTestCase {
    private var sent: [LunaRequest] = []
    private let clock = LensClock()

    private func session() -> LunaCameraSession {
        let session = LunaCameraSession(
            send: { [unowned self] in
                sent.append($0)
                return Data()
            },
            functionMode: { 7 }, readSettings: {}, readCapture: {},
            now: { [clock] in clock.read() })
        session.linkChanged(.streaming, serial: "SIMULATED-LENS")
        addTeardownBlock { @MainActor in session.close(.requested) }
        return session
    }

    private func report(
        _ session: LunaCameraSession, types: [UInt32] = [53, 93],
        zoom: Double? = nil, focus: UInt64? = nil, bank: UInt32 = 7
    ) throws {
        var settings = try LunaPhotographySettings(response: Data())
        settings.types = types
        settings.functionMode = bank
        settings.zoom = zoom
        settings.afMode = focus
        session.ingest(settings: settings)
    }

    private func command(_ value: SettingValue, _ session: LunaCameraSession) -> CameraCommand {
        CameraCommand(.set(value), preconditions: CommandPreconditions(session.current))
    }

    private func expect(
        _ command: CameraCommand, _ session: LunaCameraSession, _ stage: CommandStage,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let receipt = await session.submit(command)
        XCTAssertEqual(receipt.stage, stage, file: file, line: line)
    }

    func testCommonExposureUnknownProgramWithdrawsTheOldReport() throws {
        let source = session()
        var settings = try LunaPhotographySettings(response: LunaProtocol.setVideoExposure(
            program: .manual, iso: 400, shutterSeconds: 0.02).body)
        settings.functionMode = 7
        settings.types = [21]
        source.ingest(settings: settings)
        XCTAssertEqual(source.current.value(of: .iso).value, .iso(.manual(400)))
        var exposure = try XCTUnwrap(settings.videoExposure)
        exposure.program = 999_999
        settings.videoExposure = exposure
        source.ingest(settings: settings)
        XCTAssertNil(source.current.value(of: .iso).value, "An unknown program does not declare automatic ISO")
        XCTAssertNil(source.current.value(of: .shutter).value, "An unknown program does not declare automatic shutter")
        XCTAssertEqual(source.current.capabilities[.iso]?.availability, .unavailable(.notReady),
            "A withdrawn ISO cannot accept a combined exposure write")
        XCTAssertEqual(source.current.capabilities[.shutter]?.availability, .unavailable(.notReady))
        XCTAssertTrue(sent.isEmpty)
    }

    func testCommonExposureExplicitAbsentReportWithdrawsTheOldValues() throws {
        let source = session()
        var settings = try LunaPhotographySettings(response: LunaProtocol.setVideoExposure(
            program: .manual, iso: 400, shutterSeconds: 0.02).body)
        settings.functionMode = 7
        settings.types = [21]
        source.ingest(settings: settings)
        XCTAssertEqual(source.current.value(of: .shutter).value, .shutter(.duration(Rational(1, 50))))
        settings.videoExposure = nil
        source.ingest(settings: settings)
        XCTAssertNil(source.current.value(of: .iso).value)
        XCTAssertNil(source.current.value(of: .shutter).value)
        XCTAssertEqual(source.current.capabilities[.iso]?.availability, .unavailable(.notReady),
            "A withdrawn ISO cannot accept a combined exposure write")
        XCTAssertEqual(source.current.capabilities[.shutter]?.availability, .unavailable(.notReady))
        XCTAssertTrue(sent.isEmpty)
    }

    func testCommonExposurePreservesAReportedDurationLongerThanOneSecond() throws {
        let source = session()
        var settings = try LunaPhotographySettings(response: LunaProtocol.setVideoExposure(
            program: .manual, iso: 400, shutterSeconds: 0.02).body)
        settings.functionMode = 7
        settings.types = [21]
        var exposure = try XCTUnwrap(settings.videoExposure)
        exposure.shutterSeconds = 2
        settings.videoExposure = exposure
        source.ingest(settings: settings)
        XCTAssertEqual(source.current.value(of: .shutter).value, .shutter(.duration(Rational(2))))
        XCTAssertTrue(sent.isEmpty)
    }

    /// An explicitly requested unsupported format withdraws its old common cadence.
    func testExplicitUnknownRecordingFormatClearsTheOldCommonRate() throws {
        let session = session()
        var settings = try LunaPhotographySettings(response: Data())
        settings.types = [31]
        settings.functionMode = 7
        settings.recordResolution = 48
        session.ingest(settings: settings)
        XCTAssertEqual(session.current.value(of: .frameRate).value, .frameRate(Rational(25)))
        settings.recordResolution = 999_999
        session.ingest(settings: settings)
        XCTAssertNil(session.current.value(of: .frameRate).value, "An unsupported report cannot retain the old recording cadence")
        XCTAssertNil(session.current.recordingFormat.dimensions.value)
        XCTAssertNil(session.current.value(of: .frameRate).observedAt)
        settings.recordResolution = 48
        session.ingest(settings: settings)
        let known = session.current.value(of: .frameRate)
        XCTAssertNotNil(known.observedAt)
        settings.types = [39]
        settings.recordResolution = nil
        settings.whiteBalanceKelvin = 5600
        session.ingest(settings: settings)
        XCTAssertEqual(session.current.value(of: .frameRate), known, "An unrelated partial reply retains the cadence and timestamp")
        settings.types = [31]
        session.ingest(settings: settings)
        XCTAssertNil(session.current.value(of: .frameRate).value)
        XCTAssertNil(session.current.value(of: .frameRate).observedAt)
        XCTAssertTrue(sent.isEmpty, "Reading recording facts never sends a command")
    }

    func testExplicitUnknownRecordingProfileClearsTheOldCommonProfile() throws {
        let session = session()
        var settings = try LunaPhotographySettings(response: Data())
        settings.types = [35]
        settings.functionMode = 7
        settings.colorMode = LunaColorMode.iLog.rawValue
        session.ingest(settings: settings)
        XCTAssertNotNil(session.recordingProfile.value)
        settings.colorMode = 999_999
        session.ingest(settings: settings)
        XCTAssertNil(session.recordingProfile.value, "An unsupported report cannot retain the old recording profile")
        XCTAssertNil(session.current.recordingFormat.profile.value)
        XCTAssertTrue(sent.isEmpty, "Reading recording facts never sends a command")
    }

    func testRecordingFactsKeepIndependentProvenanceAndNeverAssumePreviewCodec() throws {
        let session = session()
        var profile = try LunaPhotographySettings(response: Data())
        profile.types = [35]
        profile.functionMode = 7
        profile.colorMode = LunaColorMode.iLog.rawValue
        session.ingest(settings: profile)
        let observedProfile = session.current.recordingFormat.profile
        XCTAssertEqual(observedProfile.value, "I-Log")
        XCTAssertEqual(observedProfile.origin, .cameraReported)
        clock.advance(.seconds(1))
        var format = try LunaPhotographySettings(response: Data())
        format.types = [31]
        format.functionMode = 7
        format.recordResolution = 48
        session.ingest(settings: format)
        XCTAssertEqual(session.current.recordingFormat.dimensions.value,
            CameraRecordingFormat.Dimensions(width: 3840, height: 2160))
        XCTAssertEqual(session.current.recordingFormat.dimensions.origin, .cameraReported)
        XCTAssertEqual(session.current.recordingFormat.dimensions.observedAt, clock.read())
        XCTAssertEqual(session.current.recordingFormat.profile, observedProfile,
            "A dimension report cannot restamp the retained profile")
        XCTAssertNil(session.current.recordingFormat.codec.value, "HEVC preview is not a recording-codec report")
        let recordedDimensions = session.current.recordingFormat.dimensions
        format.functionMode = 1
        format.recordResolution = 49
        session.ingest(settings: format)
        XCTAssertEqual(session.current.recordingFormat.dimensions, recordedDimensions)
        session.close(.replaced)
        format.functionMode = 7
        session.ingest(settings: format)
        XCTAssertEqual(session.current.recordingFormat.dimensions, recordedDimensions)
        XCTAssertTrue(sent.isEmpty)
    }

    /// A5-09: option 31's schema rate is a typed read-only Rational, never rounded or written.
    func testRecordRateIsAReadOnlyRationalFromTheResolutionOption() async throws {
        let session = session()
        XCTAssertEqual(session.current.capabilities[.frameRate]?.access, .readOnly)
        XCTAssertNil(session.current.value(of: .frameRate).value, "no report is unknown")
        var settings = try LunaPhotographySettings(response: Data())
        settings.types = [31]
        settings.functionMode = 7
        settings.recordResolution = 48  // 4K25
        session.ingest(settings: settings)
        XCTAssertEqual(session.current.value(of: .frameRate).value, .frameRate(Rational(25)))
        await expect(command(.frameRate(Rational(24)), session), session, .rejected(.readOnly))
    }

    func testLensDescriptorsRequireConfiguredZoomAndNeverInventReports() {
        let session = session()
        XCTAssertEqual(session.current.capabilities.support(of: .zoom), .unknown)
        XCTAssertEqual(
            session.current.capabilities[.focusMode]?.domain?.choices,
            [.focusMode(.single), .focusMode(.continuous)])
        XCTAssertNil(session.current.value(of: .zoom).value)
        XCTAssertNil(session.current.value(of: .focusMode).value)
        session.configureLens(zoomDomain: 1...4)
        XCTAssertEqual(session.current.capabilities[.zoom]?.domain?.range, 1...4)
        XCTAssertTrue(session.layout().zoom)
        XCTAssertTrue(session.layout().focus)
        XCTAssertNil(session.current.value(of: .zoom).value)
    }

    func testLensAcknowledgementWaitsForRampedReadbackAndResubmissionIsIdempotent() async throws {
        let session = session()
        session.configureLens(zoomDomain: 1...4)
        try report(session, zoom: 1, focus: 1)
        let zoom = command(.zoom(3), session)
        await expect(zoom, session, .awaitingObservation)
        XCTAssertEqual(session.current.value(of: .zoom).value, .zoom(1))
        XCTAssertEqual(try LunaPhotographySettings(response: sent.last!.body).zoom, 3)
        clock.advance(.milliseconds(100))
        try report(session, types: [53], zoom: 2.5)
        XCTAssertEqual(session.receipt(of: zoom.operation)?.stage, .awaitingObservation)
        try report(session, types: [53], zoom: 2.97)
        XCTAssertEqual(session.receipt(of: zoom.operation)?.stage, .confirmed)
        XCTAssertEqual(session.current.value(of: .zoom).origin, .cameraReported)
        await expect(zoom, session, .confirmed)
        XCTAssertEqual(sent.count, 1)
        let focus = command(.focusMode(.continuous), session)
        await expect(focus, session, .awaitingObservation)
        XCTAssertEqual(try LunaPhotographySettings(response: sent.last!.body).afMode, 3)
        try report(session, types: [93], focus: 3)
        XCTAssertEqual(session.receipt(of: focus.operation)?.stage, .confirmed)
    }

    func testPartialAndForeignBankReportsPreserveLensWhileMissingOrVendorValuesAreUnknown() throws {
        let session = session()
        session.configureLens(zoomDomain: 1...4)
        try report(session, zoom: 2, focus: 1)
        try report(session, types: [39])
        try report(session, zoom: 3, focus: 3, bank: 1)
        XCTAssertEqual(session.current.value(of: .zoom).value, .zoom(2))
        XCTAssertEqual(session.current.value(of: .focusMode).value, .focusMode(.single))
        try report(session, types: [93], focus: 6)
        XCTAssertNil(session.current.value(of: .focusMode).value, "Product Showcase is not AF-C")
        for invalid in [0, -1, 16, Double.infinity, Double.nan] {
            try report(session, types: [53], zoom: invalid)
            XCTAssertNil(session.current.value(of: .zoom).value)
        }
        try report(session, zoom: 2, focus: 3)
        try report(session)
        XCTAssertNil(session.current.value(of: .zoom).value)
        XCTAssertNil(session.current.value(of: .focusMode).value)
    }

    func testLensAdmissionRejectsOutOfDomainAndStaleConfiguration() async {
        let session = session()
        session.configureLens(zoomDomain: 1...4)
        await expect(command(.zoom(5), session), session, .rejected(.outOfDomain))
        await expect(command(.focusMode(.manual), session), session, .rejected(.outOfDomain))
        let old = command(.zoom(3), session)
        session.configureLens(zoomDomain: 1...2)
        await expect(old, session, .rejected(.staleCapabilities))
        session.configureLens(zoomDomain: 0...15)
        XCTAssertEqual(session.current.capabilities.support(of: .zoom), .unknown)
        XCTAssertTrue(sent.isEmpty)
    }

    func testNewestLensTargetWinsAndClosedSessionIgnoresLateReports() async throws {
        let session = session()
        session.configureLens(zoomDomain: 1...4)
        let older = command(.zoom(2), session)
        _ = await session.submit(older)
        let newer = command(.zoom(3), session)
        _ = await session.submit(newer)
        XCTAssertEqual(session.receipt(of: older.operation)?.stage, .failed(.superseded))
        try report(session, types: [53], zoom: 2)
        XCTAssertEqual(session.receipt(of: newer.operation)?.stage, .awaitingObservation)
        session.close(.replaced)
        try report(session, types: [53], zoom: 3)
        XCTAssertEqual(session.receipt(of: newer.operation)?.stage, .outcomeUnknown)
        XCTAssertEqual(session.current.value(of: .zoom).value, .zoom(2))
        await expect(command(.zoom(4), session), session, .rejected(.sessionClosed))
        XCTAssertEqual(sent.count, 2)
    }

    func testLensDeadlineDistinguishesDisagreementFromNoObservation() async throws {
        let session = session()
        session.configureLens(zoomDomain: 1...4)
        let zoom = command(.zoom(3), session)
        let focus = command(.focusMode(.continuous), session)
        _ = await session.submit(zoom)
        _ = await session.submit(focus)
        clock.advance(.seconds(5))
        try report(session, types: [53], zoom: 2)
        XCTAssertEqual(session.receipt(of: zoom.operation)?.stage, .failed(.notApplied))
        XCTAssertEqual(session.receipt(of: focus.operation)?.stage, .timedOut)
    }
}
