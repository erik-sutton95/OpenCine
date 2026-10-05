import Foundation
import OpenCineAppKit
import OpenCineMedia
import XCTest

/// Moved from the iOS apps' ReliabilityReportingTests: the reporting runtime with a recording sink
/// in place of the apps' Sentry adapter (whose own tests stay in the apps).
final class ReliabilityReportingTests: XCTestCase {
    private var suite: UserDefaults!
    private var cacheRoot: URL!
    private var consent: ReliabilityReportingConsent!
    private var gate: ReliabilityReportingGate!
    private var origin: FeedIncidentOrigin!
    private var reporting: ReliabilityReporting!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "opc.reliability.test.\(UUID().uuidString)")
        consent = ReliabilityReportingConsent(defaults: suite)
        cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("opc-rel-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        gate = ReliabilityReportingGate(cameraIPv4Prefix: "192.168.2.")
        gate.setCameraIPv4PathReadyForTests(false)
        origin = FeedIncidentOrigin(
            derivesTestSource: true, verification: false, buildIdentity: nil,
            injectionActivated: { false })
        reporting = ReliabilityReporting(
            host: TestDiagnostics.host, consent: consent,
            dsn: ReliabilityReportingDSN { [] }, gate: gate, origin: origin,
            sink: RecordingSink())
        reporting.sdkCacheRoot = cacheRoot
    }

    override func tearDown() {
        reporting.setCaptureHandlerForTests(nil)
        gate.resetForTests()
        try? FileManager.default.removeItem(at: cacheRoot)
        super.tearDown()
    }

    private func waitForReceipt(_ id: String, state: ReliabilityReportingReceiptState) {
        let reporting = reporting!
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in reporting.receipt(for: id)?.state == state },
            object: nil)
        wait(for: [ready], timeout: 10)
    }

    func testOnlyExhaustedIncidentsAreErrors() {
        XCTAssertEqual(ReliabilityReporting.level(forOutcome: "exhausted"), .error)
        XCTAssertEqual(ReliabilityReporting.level(forOutcome: "interrupted"), .warning)
        XCTAssertEqual(ReliabilityReporting.level(forOutcome: "recovered"), .info)
        XCTAssertEqual(ReliabilityReporting.level(forOutcome: "suppressed"), .info)
    }

    func testConsentDefaultsOffAndRevokePurgesOnlySDKOwnedSpool() {
        XCTAssertFalse(consent.isOptedIn)
        XCTAssertFalse(reporting.isOptedIn)
        consent.setOptedIn(true)
        XCTAssertTrue(reporting.isOptedIn)
        let localDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opc-local-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        let local = localDir.appendingPathComponent("incident-keep.json")
        try? Data("keep".utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: localDir) }
        ReliabilityReportingReceipts.store(
            ReliabilityReportingReceipt(
                incidentID: "inc-1", eventID: "abc", state: .queued, updatedAt: Date()),
            root: cacheRoot)
        XCTAssertNotNil(ReliabilityReportingReceipts.load(incidentID: "inc-1", root: cacheRoot))
        reporting.setConsent(false)
        XCTAssertFalse(reporting.isOptedIn)
        let root = cacheRoot!
        let purged = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                ReliabilityReportingReceipts.load(incidentID: "inc-1", root: root) == nil
            }, object: nil)
        wait(for: [purged], timeout: 10)
        XCTAssertNil(ReliabilityReportingReceipts.load(incidentID: "inc-1", root: cacheRoot))
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.path))
    }

    func testDecliningIsPersistedAsDecisionAndCanBeEnabledLater() {
        XCTAssertFalse(consent.hasDecision)
        consent.setOptedIn(false)
        XCTAssertTrue(consent.hasDecision)
        XCTAssertFalse(consent.isOptedIn)
        consent.setOptedIn(true)
        XCTAssertTrue(consent.isOptedIn)
    }

    func testDSNRequiresHTTPSSentryShape() {
        XCTAssertNil(ReliabilityReportingDSN.validated(""))
        XCTAssertNil(ReliabilityReportingDSN.validated("http://key@host/1"))
        XCTAssertNil(ReliabilityReportingDSN.validated("https://ingest.sentry.io/1"))
        XCTAssertNil(ReliabilityReportingDSN.validated("https://key:secret@ingest.sentry.io/1"))
        XCTAssertNil(
            ReliabilityReportingDSN.validated("https://key@ingest.sentry.io/1?token=value"))
        XCTAssertNil(
            ReliabilityReportingDSN.validated("https://key@ingest.sentry.io/not-a-project"))
        XCTAssertNotNil(
            ReliabilityReportingDSN.validated("https://publickey@o0.ingest.sentry.io/0"))
    }

    func testLaunchEnvironmentMarksAutomationWithoutXCTestClass() {
        XCTAssertTrue(
            FeedIncidentOrigin.isAutomationLaunch(["OPV_PHYSICAL_UI_REVIEW": "1"]))
        XCTAssertTrue(
            FeedIncidentOrigin.isAutomationLaunch(["OPV_UI_REVIEW_SCREEN": "live"]))
        XCTAssertTrue(
            FeedIncidentOrigin.isAutomationLaunch(["OPV_FEED_STRESS": "1"]))
        XCTAssertFalse(
            FeedIncidentOrigin.isAutomationLaunch(["OPV_UI_REVIEW_SCREEN": ""]))
        XCTAssertFalse(FeedIncidentOrigin.isAutomationLaunch([:]))
        origin.overrideTestSourceForTests = nil
        XCTAssertEqual(
            origin.currentTestSource(
                environment: ["OPV_PHYSICAL_UI_REVIEW": "1"], injectionActivated: false),
            .automation)
        XCTAssertEqual(
            origin.currentTestSource(environment: [:], injectionActivated: true),
            .faultInjection)
    }

    func testEventIDAndFingerprintAreStable() {
        let id = "12c2d058-d584-4270-9aa2-eca08bf20986"
        let first = ReliabilityReportingPrivacy.eventID(fromIncidentID: id)
        let second = ReliabilityReportingPrivacy.eventID(fromIncidentID: id)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, "12c2d058d58442709aa2eca08bf20986")
        let prints = reporting.privacy.fingerprint(
            schema: 1, kind: "freshInputStaleOutput", stage: "decodedOutput",
            errorClass: "invalidSession")
        XCTAssertEqual(
            prints,
            [
                "feed-incident", "schema:1", "kind:freshInputStaleOutput",
                "stage:decodedOutput", "errorClass:invalidSession",
            ]
        )
    }

    func testQueuedIncidentKeepsOriginalReleaseAndOccurrenceTime() throws {
        consent.setOptedIn(true)
        var bundle = try stallBundle(id: UUID().uuidString)
        bundle.header.outcome = .recovered
        bundle.header.appVersion = "0.1.0"
        bundle.header.appBuild = "107"
        bundle.header.sourceRevision = String(repeating: "a", count: 40)
        bundle.header.testSource = .faultInjection
        bundle.header.buildIdentity = "ios-0123456789abcdef0123456789abcd"
        bundle.header.startedAtWallClock = Date(timeIntervalSince1970: 1_780_000_000)
        origin.overrideTestSourceForTests = .verification
        origin.overrideBuildIdentityForTests = "ios-current-run-identity-value"
        let captured = expectation(description: "original provenance")
        let expectedTime = bundle.header.startedAtWallClock
        reporting.setCaptureHandlerForTests { event, _ in
            XCTAssertEqual(event.release, "com.opencapture.fieldmonitor@0.1.0+107")
            XCTAssertEqual(event.dist, "107")
            XCTAssertEqual(event.timestamp, expectedTime)
            XCTAssertEqual(event.tags?["sourceRevision"], String(repeating: "a", count: 40))
            XCTAssertEqual(event.tags?["testSource"], "faultInjection")
            XCTAssertEqual(event.tags?["buildIdentity"], "ios-0123456789abcdef0123456789abcd")
            XCTAssertNotEqual(event.tags?["testSource"], "verification")
            captured.fulfill()
        }
        reporting.enqueueFinalized(bundle)
        wait(for: [captured], timeout: 10)
    }

    func testImmediateConfirmationIsNotOverwrittenByQueuedReceipt() throws {
        consent.setOptedIn(true)
        let id = "cccccccccccccccccccccccccccccccc"
        var bundle = try stallBundle(id: id)
        bundle.header.outcome = .recovered
        reporting.setCaptureHandlerForTests { [reporting] event, _ in
            reporting?.noteTransportSuccess(eventID: event.eventID)
        }
        reporting.enqueueFinalized(bundle)
        waitForReceipt(id, state: .confirmed)
    }

    func testIncidentExposureDoesNotInheritPreviousSessionSummary() throws {
        consent.setOptedIn(true)
        reporting.noteSessionSummary(
            FeedIncidentSessionSummary(
                sessionID: UUID().uuidString, healthyExposureSeconds: 123456,
                incidentCount: 99, outcome: "healthy", sourceRevision: "test"))
        var bundle = try stallBundle(id: "dddddddddddddddddddddddddddddddd")
        bundle.header.outcome = .recovered
        let captured = expectation(description: "incident")
        reporting.setCaptureHandlerForTests { event, _ in
            guard event.fingerprint.first == "feed-incident" else { return }
            XCTAssertNotEqual(event.extra?["healthyExposureSeconds"] as? Double, 123456)
            XCTAssertNil(event.extra?["incidentCount"])
            captured.fulfill()
        }
        reporting.enqueueFinalized(bundle)
        wait(for: [captured], timeout: 10)
    }

    func testCaptureEnqueueIsQueuedNotDeliveredAndDedupsConfirmed() throws {
        consent.setOptedIn(true)
        var bundle = try stallBundle(id: "12c2d058d58442709aa2eca08bf20986")
        bundle.header.outcome = .recovered
        let captured = expectation(description: "handler")
        captured.expectedFulfillmentCount = 1
        reporting.setCaptureHandlerForTests { event, data in
            XCTAssertEqual(event.eventID, "12c2d058d58442709aa2eca08bf20986")
            XCTAssertEqual(event.fingerprint.first, "feed-incident")
            XCTAssertTrue(event.fingerprint.contains("kind:freshInputStaleOutput"))
            XCTAssertFalse(event.attachesRecentBreadcrumbs)
            let text = String(data: data, encoding: .utf8) ?? ""
            XCTAssertTrue(text.contains("prelude"))
            XCTAssertTrue(text.contains("repairs") || text.contains("during"))
            XCTAssertFalse(text.contains("control-live.log"))
            captured.fulfill()
        }
        reporting.enqueueFinalized(bundle)
        wait(for: [captured], timeout: 10)
        waitForReceipt("12c2d058d58442709aa2eca08bf20986", state: .queued)
        XCTAssertEqual(
            reporting.receipt(for: "12c2d058d58442709aa2eca08bf20986")?.state, .queued)
        reporting.noteTransportSuccess(eventID: "12c2d058d58442709aa2eca08bf20986")
        waitForReceipt("12c2d058d58442709aa2eca08bf20986", state: .confirmed)
        XCTAssertEqual(
            reporting.receipt(for: "12c2d058d58442709aa2eca08bf20986")?.state, .confirmed)
        let again = expectation(description: "no-second")
        again.isInverted = true
        reporting.setCaptureHandlerForTests { _, _ in again.fulfill() }
        reporting.enqueueFinalized(bundle)
        wait(for: [again], timeout: 0.3)
    }

    func testOpenCheckpointDoesNotEnqueueDuplicate() throws {
        consent.setOptedIn(true)
        let open = try stallBundle(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertEqual(open.header.outcome, .open)
        XCTAssertFalse(ReliabilityReporting.isFinalized(open))
        let captured = expectation(description: "open-must-not-capture")
        captured.isInverted = true
        reporting.setCaptureHandlerForTests { _, _ in captured.fulfill() }
        reporting.enqueueFinalized(open)
        wait(for: [captured], timeout: 0.4)
        XCTAssertNil(reporting.receipt(for: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
    }

    func testHealthyOnlyEndSummaryDoesNotClaimHealthyAtZeroExposure() {
        XCTAssertEqual(
            FeedIncidentRuntime.summaryOutcome(incidentCount: 0, exposure: 12), "healthy")
        XCTAssertEqual(
            FeedIncidentRuntime.summaryOutcome(incidentCount: 0, exposure: 0), "no-exposure")
        XCTAssertEqual(FeedIncidentRuntime.summaryOutcome(incidentCount: 2, exposure: 40), "ended")
    }

    func testDeleteStoredIncidentsClearsExtrasCache() {
        let incidents = FeedIncidentRuntime(
            reporting: reporting, directory: cacheRoot.appendingPathComponent("incidents"))
        incidents.seedExtrasCacheForTests([
            ("incident-dead.json", "should-not-share")
        ])
        XCTAssertEqual(incidents.reportExtras().count, 1)
        let done = expectation(description: "deleted")
        incidents.deleteStoredIncidents { done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertTrue(incidents.reportExtras().isEmpty)
    }

    func testRevokeAbortsQueuedCapture() throws {
        consent.setOptedIn(true)
        var bundle = try stallBundle(id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        bundle.header.outcome = .interrupted
        let captured = expectation(description: "revoked")
        captured.isInverted = true
        reporting.setCaptureHandlerForTests { _, _ in captured.fulfill() }
        reporting.enqueueFinalized(bundle)
        reporting.setConsent(false)
        wait(for: [captured], timeout: 0.5)
        XCTAssertFalse(reporting.isOptedIn)
        XCTAssertNil(reporting.receipt(for: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"))
    }

    func testTransportSuccessConfirmsOnlyMatchingEventID() {
        consent.setOptedIn(true)
        ReliabilityReportingReceipts.store(
            ReliabilityReportingReceipt(
                incidentID: "a", eventID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                state: .queued, updatedAt: Date()),
            root: cacheRoot)
        ReliabilityReportingReceipts.store(
            ReliabilityReportingReceipt(
                incidentID: "b", eventID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                state: .queued, updatedAt: Date()),
            root: cacheRoot)
        reporting.noteTransportSuccess(eventID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        waitForReceipt("a", state: .confirmed)
        XCTAssertEqual(
            ReliabilityReportingReceipts.load(incidentID: "a", root: cacheRoot)?.state,
            .confirmed)
        XCTAssertEqual(
            ReliabilityReportingReceipts.load(incidentID: "b", root: cacheRoot)?.state,
            .queued)
        var request = URLRequest(url: URL(string: "https://o0.ingest.sentry.io/api/0/envelope/")!)
        request.httpBody = Data("{\"event_id\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}\n{}".utf8)
        XCTAssertEqual(
            ReliabilityReportingEnvelopeID.eventID(from: request),
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    }

    private func stallBundle(id: String) throws -> FeedIncidentBundle {
        var recorder = FeedIncidentRecorder(makeIncidentID: { id })
        _ = recorder.beginSession(
            FeedIncidentSessionContext(
                sessionID: "session-1",
                appVersion: "0.1.0",
                appBuild: "107",
                sourceRevision: "test",
                osName: "iOS",
                osVersion: "17.0",
                hardwareClass: "iPhone17,2",
                cameraFamily: "pocket"))
        _ = recorder.recordSnapshot(
            FeedIncidentSnapshot(
                monotonicNow: 1,
                wallClock: Date(),
                rates: FeedIncidentRates(packetHz: 25, decodedOutputHz: 25, presentHz: 25),
                ages: FeedIncidentAges(
                    packetAge: 0.04, decodedOutputAge: 0.04, presentAge: 0.04),
                lifecycle: FeedIncidentLifecycle(
                    connected: true, liveEstablished: true)))
        let job = recorder.recordSnapshot(
            FeedIncidentSnapshot(
                monotonicNow: 4,
                wallClock: Date(),
                rates: FeedIncidentRates(packetHz: 25, decodeSubmitHz: 25, decodedOutputHz: 0),
                ages: FeedIncidentAges(
                    packetAge: 0.04, decodedOutputAge: 3, presentAge: 3),
                lifecycle: FeedIncidentLifecycle(
                    connected: true, liveEstablished: true)))
        return try XCTUnwrap(job?.bundle)
    }
}

/// A host like the apps' with neutral names.
enum TestDiagnostics {
    static let host = DiagnosticsHost(
        product: "Field monitor", listingName: "Field monitor",
        releasePackage: "com.opencapture.fieldmonitor", version: "0.1.0", build: "107",
        environment: "development", sourceRevision: "test",
        supportEmail: "support@example.invalid", redact: { PrivacyRedactor.redact($0) })
}

/// The SDK seam, recording nothing: capture runs through the runtime's test handler.
final class RecordingSink: ReliabilityReportingSink, @unchecked Sendable {
    var isEnabled = false
    func start(dsn: String, cacheRoot: URL) { isEnabled = true }
    func close() { isEnabled = false }
    func flush(timeout: TimeInterval) {}
    func addBreadcrumb(category: String, message: String, data: [String: String]?) {}
    func setTags(_ tags: [String: String]) {}
    func capture(_ event: ReliabilityEvent, attachment: Data, attachmentName: String) {}
}
