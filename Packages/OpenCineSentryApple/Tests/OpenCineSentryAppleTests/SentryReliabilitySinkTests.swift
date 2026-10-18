#if os(iOS)
    import Foundation
    import OpenCineAppKit
    import OpenCineMedia
    import OpenCineSentryApple
    import Sentry
    import XCTest

    /// A host of the shared adapter, as an app's diagnostics holder builds it. The release is
    /// 0.2.0+200 so a queued event's original 0.1.0+107 provenance shows it survives an upgrade.
    enum Fixture {
        static let host = DiagnosticsHost(
            product: "Host", listingName: "Host", releasePackage: "com.opencapture.host",
            version: "0.2.0", build: "200", environment: "development", sourceRevision: "test",
            supportEmail: "support@host.invalid", redact: { PrivacyRedactor.redact($0) })
        static let consent = ReliabilityReportingConsent()
        static let dsn = ReliabilityReportingDSN {
            [ProcessInfo.processInfo.environment["SENTRY_DSN"]]
        }
        static let gate = ReliabilityReportingGate(cameraIPv4Prefix: "192.168.2.")
        static let origin = FeedIncidentOrigin(
            derivesTestSource: true, verification: false, buildIdentity: nil,
            injectionActivated: { false })
        static let sink = SentryReliabilitySink(
            host: host, consent: consent, urlProtocol: FixtureURLProtocol.self)
        static let reporting = ReliabilityReporting(
            host: host, consent: consent, dsn: dsn, gate: gate, origin: origin, sink: sink)
        static let forwarder = ReliabilityReportingForwarder(reporting: reporting)
    }

    /// Metric names the adapter's filter kept, in order.
    final class MetricNames: @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [String] = []
        func append(_ name: String) { lock.withLock { kept.append(name) } }
        var names: [String] { lock.withLock { kept } }
    }

    /// The SDK's URL protocol over the fixture runtime, as each app names its forwarder.
    final class FixtureURLProtocol: ReliabilityReportingURLProtocol, @unchecked Sendable {
        override class var forwarder: ReliabilityReportingForwarder { Fixture.forwarder }
    }

    /// Moved from the apps' ReliabilityReportingTests (Sentry half; the SDK-free half is in
    /// OpenCineAppKitTests). iOS only: run on a simulator with xcodebuild.
    final class SentryReliabilitySinkTests: XCTestCase {
        private var suite: UserDefaults!
        private var cacheRoot: URL!

        override func setUp() {
            super.setUp()
            suite = UserDefaults(suiteName: "opc.reliability.test.\(UUID().uuidString)")
            Fixture.consent.defaults = suite
            Fixture.consent.resetForTests()
            cacheRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("opc-rel-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: cacheRoot, withIntermediateDirectories: true)
            Fixture.reporting.sdkCacheRoot = cacheRoot
            Fixture.reporting.setCaptureHandlerForTests(nil)
            Fixture.gate.resetForTests()
            Fixture.reporting.dsnHost = "o0.ingest.sentry.io"
            Fixture.forwarder.session = URLSession(
                configuration: {
                    let config = URLSessionConfiguration.ephemeral
                    config.waitsForConnectivity = false
                    return config
                }())
        }

        override func tearDown() {
            Fixture.gate.resetForTests()
            Fixture.consent.resetForTests()
            Fixture.consent.defaults = .standard
            Fixture.reporting.setCaptureHandlerForTests(nil)
            Fixture.origin.resetForTests()
            try? FileManager.default.removeItem(at: cacheRoot)
            super.tearDown()
        }

        func testColdStartOnCameraNetworkStillInstallsCrashCapture() {
            Fixture.consent.setOptedIn(true)
            Fixture.gate.setCameraIPv4PathReadyForTests(true)
            let previousDSN = ProcessInfo.processInfo.environment["SENTRY_DSN"]
            setenv("SENTRY_DSN", "https://publickey@o0.ingest.sentry.io/0", 1)
            defer {
                if let previousDSN {
                    setenv("SENTRY_DSN", previousDSN, 1)
                } else {
                    unsetenv("SENTRY_DSN")
                }
                Fixture.reporting.setConsent(false)
            }
            Fixture.reporting.install()
            let installed = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in SentrySDK.isEnabled }, object: nil)
            wait(for: [installed], timeout: 10)
            XCTAssertTrue(Fixture.gate.shouldBlockUpload)
        }

        func testScrubDoesNotStampCurrentOriginOntoLegacyOrFatalEvents() {
            Fixture.origin.overrideTestSourceForTests = .verification
            Fixture.origin.overrideBuildIdentityForTests = "ios-current-run-identity-value"
            let event = Event(level: .fatal)
            event.tags = ["failingStage": "decodedOutput"]
            _ = Fixture.reporting.privacy.scrub(event)
            XCTAssertNil(event.tags?["testSource"])
            XCTAssertNil(event.tags?["buildIdentity"])
            event.tags = [
                "testSource": "manual", "buildIdentity": "ios-priorrun0123456789abcdefab",
            ]
            _ = Fixture.reporting.privacy.scrub(event)
            XCTAssertEqual(event.tags?["testSource"], "manual")
            XCTAssertEqual(event.tags?["buildIdentity"], "ios-priorrun0123456789abcdefab")
        }

        func testUnknownBreadcrumbTokensAreRejected() {
            let event = Event(level: .error)
            let scene = Breadcrumb(level: .info, category: "feed")
            scene.message = "sceneActivity"
            scene.data = ["sceneState": "Erik", "assistState": "private_project"]
            let assist = Breadcrumb(level: .info, category: "feed")
            assist.message = "assistChange"
            assist.data = ["assistState": "private_project"]
            event.breadcrumbs = [scene, assist]
            _ = Fixture.reporting.privacy.scrub(event)
            XCTAssertEqual(event.breadcrumbs?.count, 2)
            XCTAssertNil(event.breadcrumbs?[0].data?["sceneState"])
            XCTAssertNil(event.breadcrumbs?[1].data?["assistState"])
        }

        func testOnlyTypedFeedBreadcrumbsSurviveScrubbing() {
            let event = Event(level: .error)
            let typed = Breadcrumb(level: .info, category: "feed")
            typed.message = "settingsEnter"
            typed.data = ["password": "must-not-leave-phone"]
            let scene = Breadcrumb(level: .info, category: "feed")
            scene.message = "sceneActivity"
            scene.data = ["sceneState": "inactive", "password": "must-not-leave-phone"]
            let repair = Breadcrumb(level: .info, category: "feed")
            repair.message = "repair"
            repair.data = ["repairAction": "decoder", "repairPhase": "requested"]
            let arbitrary = Breadcrumb(level: .info, category: "feed")
            arbitrary.message = "arbitrary operator text"
            event.breadcrumbs = [
                typed, scene, repair, arbitrary, Breadcrumb(level: .info, category: "http"),
            ]
            _ = Fixture.reporting.privacy.scrub(event)
            XCTAssertEqual(event.breadcrumbs?.count, 3)
            XCTAssertEqual(event.breadcrumbs?[0].message, "settingsEnter")
            XCTAssertNil(event.breadcrumbs?[0].data)
            XCTAssertEqual(event.breadcrumbs?[1].message, "sceneActivity")
            XCTAssertEqual(event.breadcrumbs?[1].data?["sceneState"] as? String, "inactive")
            XCTAssertNil(event.breadcrumbs?[1].data?["password"])
            XCTAssertEqual(event.breadcrumbs?[2].message, "repair")
            XCTAssertEqual(event.breadcrumbs?[2].data?["repairAction"] as? String, "decoder")
        }

        func testSDKCapturePreservesOriginalBuildAfterUpgrade() {
            Fixture.consent.setOptedIn(true)
            let options = Fixture.sink.makeOptions(
                dsn: "https://publickey@o0.ingest.sentry.io/0",
                urlSession: FixtureURLProtocol.makeSDKSession(), cacheRoot: cacheRoot)
            let prepared = expectation(description: "SDK prepared original provenance")
            options.beforeSend = { event in
                XCTAssertEqual(event.releaseName, "com.opencapture.host@0.1.0+107")
                XCTAssertEqual(event.dist, "107")
                prepared.fulfill()
                return nil
            }
            SentrySDK.start(options: options)
            defer { SentrySDK.close() }
            let event = Event(level: .error)
            event.releaseName = "com.opencapture.host@0.1.0+107"
            event.dist = "107"
            SentrySDK.capture(event: event)
            wait(for: [prepared], timeout: 10)
        }

        func testLegacyOriginalTagsCallerRemainsAvailable() {
            let scope = Scope()
            let tags = ["testSource": "faultInjection", "buildIdentity": "queued-original"]
            SentryReliabilitySink.applyOriginalTags(tags, to: scope)
            XCTAssertEqual(scope.tags["testSource"], "faultInjection")
            XCTAssertEqual(scope.tags["buildIdentity"], "queued-original")
            SentryReliabilitySink.applyOriginalTags(nil, to: scope)
            XCTAssertEqual(scope.tags["buildIdentity"], "queued-original")
        }

        func testQueuedReplayOriginSurvivesActualSDKScopeMerge() throws {
            Fixture.consent.setOptedIn(true)
            var bundle = try stallBundle(id: UUID().uuidString)
            bundle.header.outcome = .recovered
            bundle.header.kind = .transportStall
            bundle.header.testSource = .faultInjection
            bundle.header.buildIdentity = "ios-queuedorigin0123456789abcdef"
            Fixture.origin.overrideTestSourceForTests = .verification
            Fixture.origin.overrideBuildIdentityForTests = "ios-current-run-identity-value"
            let options = Fixture.sink.makeOptions(
                dsn: "https://publickey@o0.ingest.sentry.io/0",
                urlSession: FixtureURLProtocol.makeSDKSession(), cacheRoot: cacheRoot)
            let prepared = expectation(description: "SDK beforeSend original origin")
            options.beforeSend = { event in
                let scrubbed = Fixture.reporting.privacy.scrub(event)
                guard scrubbed.fingerprint?.first == "feed-incident" else { return nil }
                XCTAssertEqual(scrubbed.tags?["testSource"], "faultInjection")
                XCTAssertEqual(scrubbed.tags?["buildIdentity"], "ios-queuedorigin0123456789abcdef")
                XCTAssertTrue(scrubbed.fingerprint?.contains("kind:transportStall") == true)
                XCTAssertNotEqual(scrubbed.tags?["testSource"], "verification")
                XCTAssertNotEqual(scrubbed.tags?["buildIdentity"], "ios-current-run-identity-value")
                prepared.fulfill()
                return nil
            }
            SentrySDK.start(options: options)
            defer { SentrySDK.close() }
            SentrySDK.configureScope { scope in
                scope.setTag(value: "verification", key: "testSource")
                scope.setTag(value: "ios-current-run-identity-value", key: "buildIdentity")
            }
            let constructed = expectation(description: "constructed event")
            Fixture.reporting.setCaptureHandlerForTests { typed, attachment in
                let event = SentryReliabilitySink.event(typed)
                XCTAssertEqual(event.eventId.sentryIdString, typed.eventID)
                XCTAssertNil(event.user)
                XCTAssertEqual(event.breadcrumbs?.count, 0)
                XCTAssertEqual(event.tags?["testSource"], "faultInjection")
                XCTAssertTrue(event.fingerprint?.contains("kind:transportStall") == true)
                // Exercise the production path with the queued event's own tags.
                Fixture.sink.capture(typed, attachment: attachment, attachmentName: "incident.json")
                constructed.fulfill()
            }
            Fixture.reporting.enqueueFinalized(bundle)
            wait(for: [constructed, prepared], timeout: 10)
            SentrySDK.configureScope { scope in
                XCTAssertEqual(scope.tags["testSource"], "verification")
                XCTAssertEqual(scope.tags["buildIdentity"], "ios-current-run-identity-value")
            }
        }

        func testEventsCarryOnlyTheAnonymousInstallIDAsUser() throws {
            Fixture.consent.setOptedIn(true)
            let options = Fixture.sink.makeOptions(
                dsn: "https://publickey@o0.ingest.sentry.io/0",
                urlSession: FixtureURLProtocol.makeSDKSession(), cacheRoot: cacheRoot)
            let event = Event(level: .error)
            let user = User(userId: "device-name")
            user.email = "tester@example.com"
            event.user = user
            let sent = try XCTUnwrap(options.beforeSend?(event))
            XCTAssertEqual(sent.user?.userId, Fixture.consent.installID)
            XCTAssertNotNil(Fixture.consent.installID)
            XCTAssertNil(sent.user?.email)
            XCTAssertNil(sent.user?.username)
            XCTAssertNil(sent.user?.ipAddress)
            Fixture.consent.setOptedIn(false)
            XCTAssertNil(options.beforeSend?(Event(level: .error)))
        }

        func testHangDurationSurvivesTheScrubButOtherExceptionTextDoesNot() {
            let event = Event(level: .error)
            event.exceptions = [
                Exception(
                    value: "App hanging between 2.0 and 3.4 seconds.",
                    type: "App Hang Fully Blocked"),
                Exception(
                    value: "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil",
                    type: "NSInvalidArgumentException"),
            ]
            _ = Fixture.reporting.privacy.scrub(event)
            XCTAssertEqual(event.exceptions?[0].value, "App hanging between 2.0 and 3.4 seconds.")
            XCTAssertEqual(event.exceptions?[1].value, "Native exception")
        }

        func testOnlyTheSharedSessionMetricsLeaveThePhone() {
            Fixture.consent.setOptedIn(true)
            let options = Fixture.sink.makeOptions(
                dsn: "https://publickey@o0.ingest.sentry.io/0",
                urlSession: FixtureURLProtocol.makeSDKSession(), cacheRoot: cacheRoot)
            let filter = options.beforeSendMetric
            XCTAssertNotNil(filter)
            let kept = MetricNames()
            options.beforeSendMetric = { metric in
                if filter?(metric) != nil { kept.append(metric.name) }
                return nil
            }
            SentrySDK.start(options: options)
            defer { SentrySDK.close() }
            Fixture.sink.record(
                ReliabilityMetric(
                    name: "feed.session.incidents", value: 2, attributes: ["outcome": "ended"]))
            Fixture.sink.record(
                ReliabilityMetric(name: "feed.session.healthy_exposure", value: 40, unit: "second"))
            Fixture.sink.record(ReliabilityMetric(name: "app.other", value: 1))
            XCTAssertEqual(kept.names, ["feed.session.incidents", "feed.session.healthy_exposure"])
            Fixture.consent.setOptedIn(false)
            Fixture.sink.record(ReliabilityMetric(name: "feed.session.incidents", value: 1))
            XCTAssertEqual(kept.names.count, 2, "nothing leaves without consent")
        }

        func testScrubRemovesUserRequestBreadcrumbsAndPaths() {
            let event = Event(level: .error)
            let user = User()
            user.email = "tester@example.com"
            user.username = "example-user"
            event.user = user
            event.request = SentryRequest()
            event.breadcrumbs = [Breadcrumb(level: .info, category: "http")]
            event.tags = [
                "failingStage": "decodedOutput", "email": "tester@example.com",
                "testSource": "automation",
                "buildIdentity": "ios-0123456789abcdef0123456789abcd",
            ]
            event.extra = ["password": "hunter2", "failingStage": "decodedOutput"]
            event.context = [
                "device": [
                    "name": "Example Phone", "model": "iPhone17,2", "free_memory": 1_024,
                    "memory_size": 8_192, "thermal_state": "nominal",
                ],
                "app": ["app_memory": 512, "in_foreground": true, "device_app_hash": "x"],
                "feed": ["failingStage": "decodedOutput", "serial": "ABC"],
            ]
            event.exceptions = [
                Exception(value: "/" + "Users/example/Library/crash", type: "NSError")
            ]
            _ = Fixture.reporting.privacy.scrub(event)
            XCTAssertNil(event.user)
            XCTAssertNil(event.request)
            XCTAssertEqual(event.breadcrumbs?.count ?? 0, 0)
            XCTAssertNil(event.tags?["email"])
            XCTAssertEqual(event.tags?["failingStage"], "decodedOutput")
            XCTAssertEqual(event.tags?["testSource"], "automation")
            XCTAssertEqual(event.tags?["buildIdentity"], "ios-0123456789abcdef0123456789abcd")
            XCTAssertNil(event.extra?["password"])
            XCTAssertEqual(event.extra?["failingStage"] as? String, "decodedOutput")
            XCTAssertNil(event.context?["device"]?["name"])
            XCTAssertEqual(event.context?["device"]?["model"] as? String, "iPhone17,2")
            XCTAssertEqual(event.context?["device"]?["free_memory"] as? Int, 1_024)
            XCTAssertEqual(event.context?["device"]?["memory_size"] as? Int, 8_192)
            XCTAssertEqual(event.context?["device"]?["thermal_state"] as? String, "nominal")
            XCTAssertEqual(event.context?["app"]?["app_memory"] as? Int, 512)
            XCTAssertEqual(event.context?["app"]?["in_foreground"] as? Bool, true)
            XCTAssertNil(event.context?["app"]?["device_app_hash"])
            XCTAssertNil(event.context?["feed"]?["serial"])
            XCTAssertFalse(event.exceptions?.first?.value?.contains("example/Library") ?? true)
        }

        func testOptionsPrivacyFlags() {
            let session = FixtureURLProtocol.makeSDKSession()
            let options = Fixture.sink.makeOptions(
                dsn: "https://publickey@o0.ingest.sentry.io/0", urlSession: session,
                cacheRoot: cacheRoot)
            XCTAssertFalse(options.sendDefaultPii)
            XCTAssertFalse(options.enableSwizzling)
            XCTAssertFalse(options.enableNetworkBreadcrumbs)
            XCTAssertFalse(options.enableAutoSessionTracking)
            XCTAssertFalse(options.enableAutoPerformanceTracing)
            XCTAssertEqual(options.tracesSampleRate?.intValue ?? 0, 0)
            XCTAssertFalse(options.attachScreenshot)
            XCTAssertFalse(options.attachViewHierarchy)
            XCTAssertFalse(options.enableMetricKit)
            XCTAssertTrue(options.enableCrashHandler)
            XCTAssertTrue(options.enableAppHangTracking)
            // Tests run a development build: reinstalls must not read as watchdog kills.
            XCTAssertEqual(Fixture.host.environment, "development")
            XCTAssertFalse(options.enableWatchdogTerminationTracking)
            XCTAssertEqual(options.maxCacheItems, 30)
            XCTAssertEqual(options.maxAttachmentSize, 256 * 1_024)
            XCTAssertEqual(options.sessionReplay.sessionSampleRate, 0)
            XCTAssertEqual(options.sessionReplay.onErrorSampleRate, 0)
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
#endif
