import Foundation
import OpenCineAppKit
import OpenCineMedia
import XCTest

/// Moved from the iOS apps' ReliabilityReportingTests: the SDK's URL protocol, the verification
/// incident and the receipt TTL, on a runtime with the recording sink. The Sentry SDK cases stay
/// with each app's adapter.
final class ReliabilityReportingTransportTests: XCTestCase {
    private var suite: UserDefaults!
    private var cacheRoot: URL!
    private var consent: ReliabilityReportingConsent!
    private var gate: ReliabilityReportingGate!
    private var reporting: ReliabilityReporting!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "opc.reliability.test.\(UUID().uuidString)")
        consent = ReliabilityReportingConsent(defaults: suite)
        consent.resetForTests()
        cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("opc-rel-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        gate = ReliabilityReportingGate(cameraIPv4Prefix: "192.168.2.")
        gate.resetForTests()
        reporting = ReliabilityReporting(
            host: TestDiagnostics.host, consent: consent,
            dsn: ReliabilityReportingDSN { [] }, gate: gate,
            origin: FeedIncidentOrigin(
                derivesTestSource: true, verification: false, buildIdentity: nil,
                injectionActivated: { false }),
            sink: RecordingSink())
        reporting.sdkCacheRoot = cacheRoot
        reporting.dsnHost = "o0.ingest.sentry.io"
        let forwarder = ReliabilityReportingForwarder(reporting: reporting)
        forwarder.session = URLSession(
            configuration: {
                let config = URLSessionConfiguration.ephemeral
                config.waitsForConnectivity = false
                return config
            }())
        TestReportingURLProtocol.current = forwarder
    }

    override func tearDown() {
        gate.resetForTests()
        consent.resetForTests()
        reporting.setCaptureHandlerForTests(nil)
        TestReportingURLProtocol.current = nil
        try? FileManager.default.removeItem(at: cacheRoot)
        super.tearDown()
    }

    func testRefusedSDKRequestsFailWithoutHTTPResponse() {
        let envelopeURL = URL(string: "https://o0.ingest.sentry.io/api/0/envelope/")!
        let cases: [(name: String, optedIn: Bool?, cameraActive: Bool, url: URL, code: Int)] = [
            (
                "camera session blocks the SDK", nil, true, envelopeURL,
                NSURLErrorNotConnectedToInternet
            ),
            (
                "revoked consent blocks a cached envelope", false, false, envelopeURL,
                NSURLErrorNotConnectedToInternet
            ),
            (
                "host isolation rejects a non-DSN host", true, false,
                URL(string: "https://example.com/secret")!, NSURLErrorCannotFindHost
            ),
        ]
        for c in cases {
            consent.resetForTests()
            gate.resetForTests()
            if let optedIn = c.optedIn { consent.setOptedIn(optedIn) }
            let lease = c.cameraActive ? gate.beginCameraPath() : nil
            defer { lease?.end() }
            let session = TestReportingURLProtocol.makeSDKSession()
            let done = expectation(description: c.name)
            nonisolated(unsafe) var response: URLResponse?
            nonisolated(unsafe) var code: Int?
            session.dataTask(with: c.url) { _, resp, error in
                response = resp
                code = (error as NSError?)?.code
                done.fulfill()
            }.resume()
            wait(for: [done], timeout: 10)
            XCTAssertNil(response, c.name)
            XCTAssertEqual(code, c.code, c.name)
        }
    }

    func testCameraActivationCancelsInFlightForwardWithoutResponse() {
        consent.setOptedIn(true)
        SlowForwardProtocol.reset()
        let forwardConfig = URLSessionConfiguration.ephemeral
        forwardConfig.protocolClasses = [SlowForwardProtocol.self]
        TestReportingURLProtocol.current.session = URLSession(configuration: forwardConfig)
        let session = TestReportingURLProtocol.makeSDKSession()
        let url = URL(string: "https://o0.ingest.sentry.io/api/0/envelope/")!
        let done = expectation(description: "race")
        nonisolated(unsafe) var response: URLResponse?
        session.dataTask(with: url) { _, resp, error in
            response = resp
            XCTAssertEqual((error as NSError?)?.code, NSURLErrorNotConnectedToInternet)
            done.fulfill()
        }.resume()
        wait(for: [SlowForwardProtocol.started], timeout: 10)
        let lease = reporting.beginCameraPath()
        defer { lease.end() }
        wait(for: [done], timeout: 10)
        XCTAssertNil(response)
    }

    func testVerificationUsesTheRealRecorderAndProducesRecoveredIncident() throws {
        let verification = ReliabilityReportingVerification(
            reporting: reporting, sdkEnabled: { false }, crash: {}, isActive: { true })
        let id = UUID().uuidString
        let bundle = try XCTUnwrap(verification.syntheticIncident(id: id))
        XCTAssertEqual(bundle.header.incidentID, id)
        XCTAssertEqual(bundle.header.outcome, .recovered)
        XCTAssertEqual(bundle.header.failingStage, .decodedOutput)
        XCTAssertEqual(bundle.header.cameraFamily, "synthetic")
        XCTAssertFalse(bundle.prelude.isEmpty)
        XCTAssertEqual(bundle.breadcrumbs.first?.kind, .settingsEnter)
    }

    func testReceiptTTL() {
        let old = ReliabilityReportingReceipt(
            incidentID: "old", eventID: "e", state: .queued,
            updatedAt: Date(timeIntervalSince1970: 1))
        ReliabilityReportingReceipts.store(old, root: cacheRoot)
        let url = ReliabilityReportingReceipts.directory(root: cacheRoot)
            .appendingPathComponent("old.json")
        try? FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: url.path)
        ReliabilityReportingReceipts.applyTTL(
            root: cacheRoot, now: Date(), ttl: 10)
        XCTAssertNil(ReliabilityReportingReceipts.load(incidentID: "old", root: cacheRoot))
    }
}

/// An app's subclass: names the forwarder of the runtime under test.
private final class TestReportingURLProtocol: ReliabilityReportingURLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var current: ReliabilityReportingForwarder!
    override class var forwarder: ReliabilityReportingForwarder { current }
}

private final class SlowForwardProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var started = XCTestExpectation(description: "slow-start")

    static func reset() {
        started = XCTestExpectation(description: "slow-start")
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.started.fulfill() }
    override func stopLoading() {}
}
