import Foundation
@testable import OpenCineAppKit
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

    func testLegacySinkConformerAllowsAnOptionalMetricSample() {
        let legacy = RecordingSink()
        let sink: any ReliabilityReportingSink = legacy
        sink.record(ReliabilityMetric(name: "feed.session.incidents", value: 1))
        XCTAssertFalse(legacy.isEnabled)
        XCTAssertTrue(legacy.tags.isEmpty)
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

    func testActualRuntimeFactoryBuildsPrivateIncidentEventThroughFakeCapture() throws {
        consent.setOptedIn(true)
        var producerHost = TestDiagnostics.host
        producerHost.sourceRevision = String(repeating: "a", count: 40)
        reporting = ReliabilityReporting(
            host: producerHost, consent: consent,
            dsn: ReliabilityReportingDSN { [] }, gate: gate, origin: origin, sink: RecordingSink())
        reporting.sdkCacheRoot = cacheRoot
        let directory = cacheRoot.appendingPathComponent("SIMULATED-incidents")
        let writer = DispatchQueue(label: "test.producer.event")
        let runtime = FeedIncidentRuntime(
            reporting: reporting, directory: directory,
            writerQueue: writer, clock: { 5 })
        let captured = expectation(description: "actual producer event")
        let context = runtime.sessionContext(
            cameraFamily: "simulated",
            cameraFirmware: "SIMULATED-secret@example.invalid")
        reporting.setCaptureHandlerForTests { event, attachment in
            XCTAssertEqual(event.tags?["hardwareClass"], context.hardwareClass)
            XCTAssertEqual(event.tags?["sourceRevision"], context.sourceRevision)
            XCTAssertEqual(
                event.release,
                TestDiagnostics.host.release(version: context.appVersion, build: context.appBuild))
            XCTAssertFalse(
                String(decoding: attachment, as: UTF8.self).contains(
                    "SIMULATED-secret@example.invalid"))
            XCTAssertFalse(event.attachesRecentBreadcrumbs)
            captured.fulfill()
        }
        runtime.install()
        let source = runtime.beginBoundSession(context)
        source.ingestSnapshot(
            .init(
                monotonicNow: 4, wallClock: Date(),
                ages: .init(accessUnitAge: 0.04, decodedOutputAge: 3, presentAge: 3),
                lifecycle: .init(connected: true, liveEstablished: true)))
        writer.sync {}
        source.endSession(now: 5)
        writer.sync {}
        wait(for: [captured], timeout: 10)
        let bundle = try XCTUnwrap(
            FeedIncidentStore(directory: directory, product: "SIMULATED").loadAll().first)
        XCTAssertEqual(bundle.header.sessionID, context.sessionID)
        XCTAssertEqual(bundle.header.outcome, .userEnded)
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

    /// The decoder status, codec and watchdog hold reach the event as searchable tags and
    /// extras, closed or bounded like the other incident fields.
    func testIncidentEventCarriesDecoderStatusCodecAndWatchdogHold() throws {
        consent.setOptedIn(true)
        var bundle = try stallBundle(id: "5a1d3c6e8f2b4d7a9c0e1f2a3b4c5d6e")
        bundle.header.outcome = .recovered
        var snapshot = try XCTUnwrap(bundle.during.last ?? bundle.prelude.last)
        snapshot.decoder = FeedIncidentDecoder(
            codec: "hevc", lastStatus: -12909, errorClass: "nativeDecoder",
            firstError: FeedIncidentDecodeErrorContext(
                status: -12909, nalTypes: [19], accessUnitBytes: 4_000))
        snapshot.watchdogGate = FeedIncidentWatchdogGate(hold: "rungWait")
        bundle.during = [snapshot]
        let captured = expectation(description: "incident event")
        reporting.setCaptureHandlerForTests { event, _ in
            XCTAssertEqual(event.tags?["decoderStatus"], "-12909")
            XCTAssertEqual(event.tags?["decoderCodec"], "hevc")
            XCTAssertEqual(event.tags?["watchdogHold"], "rungWait")
            XCTAssertEqual(event.extra?["decoderStatus"] as? String, "-12909")
            XCTAssertEqual(event.extra?["watchdogHold"] as? String, "rungWait")
            captured.fulfill()
        }
        reporting.enqueueFinalized(bundle)
        wait(for: [captured], timeout: 10)
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

    func testInstallIDExistsOnlyUnderConsentAndResetsWhenWithdrawn() throws {
        XCTAssertNil(consent.installID, "undecided: no id")
        consent.setOptedIn(false)
        XCTAssertNil(consent.installID, "declined: no id")
        XCTAssertNil(suite.object(forKey: ReliabilityReportingConsent.installIDKey))
        consent.setOptedIn(true)
        let first = try XCTUnwrap(consent.installID)
        XCTAssertNotNil(UUID(uuidString: first), "a random UUID, nothing derived from the device")
        XCTAssertEqual(consent.installID, first)
        XCTAssertEqual(
            ReliabilityReportingConsent(defaults: suite).installID, first, "kept across launches")
        consent.setOptedIn(false)
        XCTAssertNil(consent.installID)
        XCTAssertNil(
            suite.object(forKey: ReliabilityReportingConsent.installIDKey), "withdrawal deletes it")
        consent.setOptedIn(true)
        XCTAssertNotEqual(try XCTUnwrap(consent.installID), first, "a new opt-in starts a new id")
    }

    func testSessionSummaryIsAMetricNotAnIssueEvent() {
        consent.setOptedIn(true)
        let summary = FeedIncidentSessionSummary(
            sessionID: UUID().uuidString, healthyExposureSeconds: 42.5, incidentCount: 2,
            outcome: "ended", sourceRevision: "test", appVersion: "0.1.0", appBuild: "107",
            testSource: .manual, buildIdentity: nil)
        let noEvent = expectation(description: "no issue event")
        noEvent.isInverted = true
        reporting.setCaptureHandlerForTests { event, _ in
            if event.fingerprint.first == "feed-session" { noEvent.fulfill() }
        }
        let recorded = expectation(description: "two metrics")
        recorded.expectedFulfillmentCount = 2
        let metrics = MetricLog()
        reporting.setMetricHandlerForTests { metric in
            metrics.append(metric)
            recorded.fulfill()
        }
        reporting.noteSessionSummary(summary)
        wait(for: [recorded, noEvent], timeout: 2)
        let byName = Dictionary(uniqueKeysWithValues: metrics.all.map { ($0.name, $0) })
        XCTAssertEqual(byName["feed.session.healthy_exposure"]?.value, 42.5)
        XCTAssertEqual(byName["feed.session.healthy_exposure"]?.unit, "second")
        XCTAssertEqual(byName["feed.session.incidents"]?.value, 2)
        XCTAssertEqual(byName["feed.session.incidents"]?.attributes["outcome"], "ended")
        XCTAssertEqual(byName["feed.session.incidents"]?.attributes["testSource"], "manual")
        XCTAssertEqual(byName["feed.session.incidents"]?.attributes["appBuild"], "107")
        XCTAssertEqual(
            Set(metrics.all.map(\.name)), ReliabilityReportingPrivacy.metricAllowlist)
        let again = expectation(description: "recorded once")
        again.isInverted = true
        reporting.setMetricHandlerForTests { _ in again.fulfill() }
        reporting.noteSessionSummary(summary)
        wait(for: [again], timeout: 0.5)
    }

    func testEnvironmentNamesWhereTheBuildCameFrom() {
        func apple(
            debug: Bool = false, verification: Bool = false, simulator: Bool = false,
            profile: Bool = false, receipt: String? = "receipt"
        ) -> ReliabilityEnvironment {
            .apple(
                debug: debug, verification: verification, simulator: simulator,
                embeddedProfile: profile, receiptName: receipt)
        }
        XCTAssertEqual(apple(debug: true), .development)
        XCTAssertEqual(apple(debug: true, verification: true), .verification)
        XCTAssertEqual(apple(profile: true), .local, "an Xcode or ad hoc release install")
        XCTAssertEqual(apple(profile: true, receipt: "sandboxReceipt"), .local)
        XCTAssertEqual(apple(simulator: true), .local)
        XCTAssertEqual(apple(receipt: "sandboxReceipt"), .testflight)
        XCTAssertEqual(apple(), .production)
        XCTAssertEqual(apple(receipt: nil), .production)
        var host = TestDiagnostics.host
        host.environment = ReliabilityEnvironment.local.rawValue
        XCTAssertFalse(host.tracksWatchdogTerminations, "a local reinstall is not a watchdog kill")
        host.environment = ReliabilityEnvironment.testflight.rawValue
        XCTAssertTrue(host.tracksWatchdogTerminations)
    }

    func testOnlyTheSDKsLifecycleExceptionTextSurvives() {
        for kept in [
            "App hanging for at least 2000 ms.", "App hanging between 2.0 and 3.4 seconds.",
            "The user or the OS watchdog terminated your app while it blocked the main thread for between 2.0 and 9.1 seconds.",
            "The OS watchdog terminated your app, possibly because it overused RAM.",
            "Application Not Responding for at least 5000 ms.", "Background ANR",
        ] {
            XCTAssertEqual(ReliabilityReportingPrivacy.exceptionValue(kept), kept)
        }
        for replaced in [
            "App hanging between 2.0 and 3.4 seconds. /" + "Users/example", "nil insert at index 3",
            "Application Not Responding for at least 5000 ms. tester@example.com",
        ] {
            XCTAssertEqual(ReliabilityReportingPrivacy.exceptionValue(replaced), "Native exception")
        }
    }

    func testTheFeedUpscalerIsAScopeTagFromSDKStartOn() {
        consent.setOptedIn(true)
        let sink = RecordingSink()
        let started = ReliabilityReporting(
            host: TestDiagnostics.host, consent: consent,
            dsn: ReliabilityReportingDSN { ["https://publickey@o0.ingest.sentry.io/0"] },
            gate: gate,
            origin: origin, sink: sink)
        started.sdkCacheRoot = cacheRoot
        started.noteFeedUpscaler("AI")
        XCTAssertEqual(started.scopeTags["feedUpscaler"], "AI", "remembered before the SDK starts")
        started.install()
        let tagged = expectation(
            for: NSPredicate { _, _ in sink.tags["feedUpscaler"] == "AI" }, evaluatedWith: nil)
        wait(for: [tagged], timeout: 5)
        started.noteFeedUpscaler("Quality")
        XCTAssertEqual(sink.tags["feedUpscaler"], "Quality")
        XCTAssertEqual(
            ReliabilityReportingPrivacy(redact: { $0 }).tags(["feedUpscaler": "Quality"])?[
                "feedUpscaler"], "Quality",
            "the scrub keeps it")
        started.setConsent(false)
    }

    /// Security review (privacy-unsanitized-telemetry): free text planted in every runtime input
    /// that reaches a reported field never reaches the sink. Inputs: repair action and reason
    /// (trigger, recoveredBy, attachment), the build values (scope tags, incident tags and
    /// attachment, metric attributes), the session outcome and build number (metrics), the feed
    /// upscaler (scope tag) and a stored install id.
    func testNoPlantedSecretReachesTheSink() throws {
        let secrets = [
            "OpenCapture-Guest-5G", "ZR_6002199", "/\u{0055}sers/erik/Movies/take.mov",
            "tester@example.com", "203.0.113.7", "192.168.1.23",
        ]
        consent.setOptedIn(true)
        let sent = TextLog()
        let captured = expectation(description: "every planted incident")
        captured.expectedFulfillmentCount = secrets.count
        reporting.setCaptureHandlerForTests { event, json in
            sent.append(event.message)
            sent.append(event.fingerprint.joined(separator: " "))
            sent.append((event.tags ?? [:]).map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            sent.append(String(describing: event.extra ?? [:]))
            sent.append(String(describing: event.context ?? [:]))
            sent.append(String(decoding: json, as: UTF8.self))
            captured.fulfill()
        }
        let recorded = expectation(description: "every planted session")
        recorded.expectedFulfillmentCount = secrets.count * 2
        reporting.setMetricHandlerForTests { metric in
            sent.append(metric.name + " " + (metric.unit ?? ""))
            sent.append(metric.attributes.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            recorded.fulfill()
        }
        for secret in secrets {
            var bundle = try stallBundle(id: UUID().uuidString)
            bundle.header.outcome = .recovered
            bundle.header.sourceRevision = secret
            bundle.header.buildIdentity = secret
            bundle.repairs = [
                FeedRepairRecord(
                    monotonicAt: 4.5, action: secret, phase: .requested, reason: secret)
            ]
            reporting.enqueueFinalized(bundle)
            reporting.noteSessionSummary(
                FeedIncidentSessionSummary(
                    sessionID: UUID().uuidString, healthyExposureSeconds: 3, incidentCount: 1,
                    outcome: secret, sourceRevision: secret, appVersion: "0.1.0", appBuild: secret,
                    testSource: .manual, buildIdentity: secret))
            var host = TestDiagnostics.host
            host.sourceRevision = secret
            origin.overrideBuildIdentityForTests = secret
            let planted = ReliabilityReporting(
                host: host, consent: consent, dsn: ReliabilityReportingDSN { [] }, gate: gate,
                origin: origin, sink: RecordingSink())
            planted.noteFeedUpscaler(secret)
            sent.append(planted.scopeTags.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            suite.set(secret, forKey: ReliabilityReportingConsent.installIDKey)
            sent.append(consent.installID ?? "")
        }
        wait(for: [captured, recorded], timeout: 10)
        let started = RecordingSink()
        let live = ReliabilityReporting(
            host: TestDiagnostics.host, consent: consent,
            dsn: ReliabilityReportingDSN { ["https://publickey@o0.ingest.sentry.io/0"] },
            gate: gate,
            origin: origin, sink: started)
        live.sdkCacheRoot = cacheRoot
        live.install()
        wait(
            for: [expectation(for: NSPredicate { _, _ in started.isEnabled }, evaluatedWith: nil)],
            timeout: 5)
        for secret in secrets { live.noteFeedUpscaler(secret) }
        sent.append(started.tags.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        live.setConsent(false)
        for secret in secrets {
            XCTAssertFalse(sent.all.contains { $0.contains(secret) }, "\(secret) reached the sink")
        }
        XCTAssertTrue(sent.all.contains { $0.contains("trigger=other") }, "the field is still sent")
    }

    func testMutatedRepairIsClosedBeforeExportAndAttachment() throws {
        let secret = "SIMULATED-private-network"
        var bundle = try stallBundle(id: UUID().uuidString)
        var repair = FeedRepairRecord(
            monotonicAt: 4.5, action: "decoder",
            phase: .requested, reason: "outputSilence")
        repair.action = secret
        repair.reason = secret
        bundle.repairs = [repair]
        bundle.header.outcome = .recovered
        let envelope = FeedIncidentExport.envelope(from: bundle)
        XCTAssertEqual(envelope.trigger, "other")
        XCTAssertEqual(envelope.recoveredBy, "other")
        let payload = try XCTUnwrap(ReliabilityReportingPrivacy.typedJSON(from: bundle))
        XCTAssertFalse(String(decoding: payload, as: UTF8.self).contains(secret))
    }

    func testUndeclaredSocTagIsRemoved() {
        let policy = ReliabilityReportingPrivacy(redact: { PrivacyRedactor.redact($0) })
        XCTAssertNil(policy.tags(["soc": "SIMULATED-private-device-value"]))
    }

    /// Kotlin twin: the diagnostics half of
    /// `incidentTitleNamesItsKindAndTagsCarryTriggerRecoveryAndGapLikeIos`.
    func testIncidentDiagnosticsAreTaggedAndClosed() throws {
        consent.setOptedIn(true)
        var bundle = try stallBundle(id: UUID().uuidString)
        bundle.header.outcome = .recovered
        let envelope = FeedIncidentExport.envelope(from: bundle)
        let sent = TextLog()
        let delivered = expectation(description: "incident event")
        reporting.setCaptureHandlerForTests { event, _ in
            sent.append("tag background=\(event.tags?["background"] ?? "missing")")
            sent.append("tag awaitingIrap=\(event.tags?["awaitingIrap"] ?? "missing")")
            sent.append("extra background=\(event.extra?["background"] as? String ?? "missing")")
            delivered.fulfill()
        }
        reporting.enqueueFinalized(bundle)
        wait(for: [delivered], timeout: 5)
        XCTAssertTrue(["yes", "no", "unknown"].contains(envelope.background))
        XCTAssertTrue(sent.all.contains("tag background=\(envelope.background)"))
        XCTAssertTrue(sent.all.contains("tag awaitingIrap=\(envelope.awaitingIrap)"))
        XCTAssertTrue(sent.all.contains("extra background=\(envelope.background)"))
        let policy = ReliabilityReportingPrivacy(redact: { PrivacyRedactor.redact($0) })
        XCTAssertEqual(policy.tags(["background": "ZR_6002199"])?["background"], "other")
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

/// Text handed toward the SDK, read after the test's expectations are met.
final class TextLog: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    func append(_ text: String) { lock.withLock { texts.append(text) } }
    var all: [String] { lock.withLock { texts } }
}

/// Metrics the runtime recorded, read after the test's expectations are met.
final class MetricLog: @unchecked Sendable {
    private let lock = NSLock()
    private var metrics: [ReliabilityMetric] = []
    func append(_ metric: ReliabilityMetric) { lock.withLock { metrics.append(metric) } }
    var all: [ReliabilityMetric] { lock.withLock { metrics } }
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
    /// The scope tags the runtime set, main thread.
    var tags: [String: String] = [:]
    func start(dsn: String, cacheRoot: URL) { isEnabled = true }
    func close() { isEnabled = false }
    func flush(timeout: TimeInterval) {}
    func addBreadcrumb(category: String, message: String, data: [String: String]?) {}
    func setTags(_ tags: [String: String]) { self.tags.merge(tags) { _, new in new } }
    func capture(_ event: ReliabilityEvent, attachment: Data, attachmentName: String) {}
}

final class DiagnosticsHostCompatibilityTests: XCTestCase {
    func testLegacyInitializerAndPublicPropertiesRemainAvailable() {
        let host = DiagnosticsHost(
            product: "Host", listingName: "Host listing", releasePackage: "com.opencapture.host",
            version: "1", build: "1", environment: "development", sourceRevision: "test",
            supportEmail: "support@example.invalid",
            redact: { $0.replacingOccurrences(of: "private", with: "redacted") })
        XCTAssertEqual(host.product, "Host")
        XCTAssertEqual(host.listingName, "Host listing")
        XCTAssertEqual(host.environment, "development")
        XCTAssertEqual(host.release(), "com.opencapture.host@1+1")
        XCTAssertEqual(host.release(version: "2", build: "3"), "com.opencapture.host@2+3")
        XCTAssertEqual(host.redact("private sample"), "redacted sample")
    }

    func testExplicitChannelAndValueCopyRemainAuthoritative() {
        let host = DiagnosticsHost(
            product: "Host", listingName: "Host listing", releasePackage: "com.opencapture.host",
            version: "1", build: "1", environment: "local", sourceRevision: "test",
            supportEmail: "support@example.invalid", redact: { $0 })
        var copy = host
        copy.environment = "production"
        XCTAssertEqual(host.environment, "local")
        XCTAssertEqual(copy.environment, "production")
        XCTAssertFalse(host.tracksWatchdogTerminations)
        XCTAssertTrue(copy.tracksWatchdogTerminations)
    }
}
