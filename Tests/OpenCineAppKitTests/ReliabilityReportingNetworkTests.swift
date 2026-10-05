import Foundation
import OpenCineAppKit
import XCTest

/// Moved from the iOS apps' ReliabilityReportingEnvelopeTests, ReliabilityReportingTests and
/// ProblemReportingTests; the app's shared gate is a gate over the apps' camera network prefix here.
final class ReliabilityReportingNetworkTests: XCTestCase {
    private let gate = ReliabilityReportingGate(cameraIPv4Prefix: "192.168.2.")
    private let eventID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let otherID = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    override func setUp() {
        super.setUp()
        gate.resetForTests()
    }

    override func tearDown() {
        gate.resetForTests()
        super.tearDown()
    }

    func testGzipEnvelopeHeaderYieldsEventID() throws {
        let plain = envelope(eventID: eventID, trailer: String(repeating: "x", count: 8_192))
        let gzipped = try XCTUnwrap(ReliabilityReportingGzip.deflateForTests(plain))
        XCTAssertEqual(gzipped[0], 0x1F)
        XCTAssertEqual(gzipped[1], 0x8B)
        XCTAssertNil(
            ReliabilityReportingEnvelopeID.eventID(
                fromBody: gzipped, contentEncoding: "identity"),
            "gzip bytes must not parse as plaintext JSON")
        XCTAssertEqual(
            ReliabilityReportingEnvelopeID.eventID(fromBody: gzipped, contentEncoding: "gzip"),
            eventID)
        var request = URLRequest(url: URL(string: "https://o0.ingest.sentry.io/api/0/envelope/")!)
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        request.httpBody = gzipped
        XCTAssertEqual(ReliabilityReportingEnvelopeID.eventID(from: request), eventID)
    }

    func testGzipMagicWithoutContentEncodingStillParses() throws {
        let gzipped = try XCTUnwrap(
            ReliabilityReportingGzip.deflateForTests(envelope(eventID: eventID)))
        XCTAssertEqual(
            ReliabilityReportingEnvelopeID.eventID(fromBody: gzipped, contentEncoding: nil),
            eventID)
    }

    func testHttpBodyStreamDoesNotRequirePlaintextBody() throws {
        let gzipped = try XCTUnwrap(
            ReliabilityReportingGzip.deflateForTests(envelope(eventID: eventID)))
        var request = URLRequest(url: URL(string: "https://o0.ingest.sentry.io/api/0/envelope/")!)
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        request.httpBodyStream = InputStream(data: gzipped)
        let materialized = ReliabilityReportingEnvelopeID.materialized(request)
        XCTAssertEqual(materialized.1, gzipped)
        XCTAssertEqual(materialized.0.httpBody, gzipped)
        XCTAssertNil(materialized.0.httpBodyStream)
        XCTAssertEqual(
            ReliabilityReportingEnvelopeID.eventID(
                fromBody: materialized.1, contentEncoding: "gzip"),
            eventID)
    }

    func testMalformedAndTruncatedGzipYieldNil() {
        XCTAssertNil(
            ReliabilityReportingEnvelopeID.eventID(
                fromBody: Data([0x1F, 0x8B, 0x08, 0x00, 0xFF]), contentEncoding: "gzip"))
        XCTAssertNil(
            ReliabilityReportingEnvelopeID.eventID(
                fromBody: Data([0x1F, 0x8B]), contentEncoding: "gzip"))
        XCTAssertNil(
            ReliabilityReportingEnvelopeID.eventID(
                fromBody: Data("not-gzip".utf8), contentEncoding: "gzip"))
        let truncated = ReliabilityReportingGzip.deflateForTests(envelope(eventID: eventID))
            .map { Data($0.prefix(8)) }
        XCTAssertNil(
            ReliabilityReportingEnvelopeID.eventID(fromBody: truncated, contentEncoding: "gzip"))
    }

    func testOversizedHeaderWithoutNewlineIsBounded() throws {
        let huge = Data(repeating: 0x41, count: ReliabilityReportingEnvelopeID.maxHeaderBytes + 64)
        let gzipped = try XCTUnwrap(ReliabilityReportingGzip.deflateForTests(huge))
        XCTAssertNil(
            ReliabilityReportingEnvelopeID.eventID(fromBody: gzipped, contentEncoding: "gzip"))
        let inflated = ReliabilityReportingGzip.inflateHeader(
            from: gzipped, maxOutput: ReliabilityReportingEnvelopeID.maxHeaderBytes)
        XCTAssertLessThanOrEqual(
            inflated?.count ?? 0, ReliabilityReportingEnvelopeID.maxHeaderBytes)
    }

    func testNonmatchingAndShortEventIDsAreRejected() {
        let short = envelope(eventID: "abc")
        XCTAssertNil(
            ReliabilityReportingEnvelopeID.eventID(fromBody: short, contentEncoding: nil))
        let gzipped = ReliabilityReportingGzip.deflateForTests(envelope(eventID: otherID))
        XCTAssertNotEqual(
            ReliabilityReportingEnvelopeID.eventID(fromBody: gzipped, contentEncoding: "gzip"),
            eventID)
        XCTAssertNil(
            ReliabilityReportingEnvelopeID.eventID(
                fromBody: Data("{\"sent_at\":\"1\"}\n".utf8), contentEncoding: nil))
    }

    func testRedirectsOffDSNHostAreRejected() {
        let dsn = "o0.ingest.sentry.io"
        XCTAssertTrue(
            ReliabilityReportingRedirectGuard.shouldFollow(
                url: URL(string: "https://o0.ingest.sentry.io/api/1/envelope/"),
                dsnHost: dsn))
        XCTAssertFalse(
            ReliabilityReportingRedirectGuard.shouldFollow(
                url: URL(string: "https://evil.example/steal"),
                dsnHost: dsn))
        XCTAssertFalse(
            ReliabilityReportingRedirectGuard.shouldFollow(
                url: URL(string: "http://o0.ingest.sentry.io/api/1/envelope/"),
                dsnHost: dsn))
        XCTAssertFalse(ReliabilityReportingRedirectGuard.shouldFollow(url: nil, dsnHost: dsn))
    }

    func testCameraGateStillBlocksForwardDecision() {
        gate.resetForTests()
        let url = URL(string: "https://o0.ingest.sentry.io/api/0/envelope/")!
        XCTAssertEqual(
            ReliabilityReportingNetwork.decision(for: url, dsnHost: url.host, gate: gate),
            .forward)
        gate.setCameraSessionActive(true)
        XCTAssertEqual(
            ReliabilityReportingNetwork.decision(for: url, dsnHost: url.host, gate: gate),
            .blockCameraPath)
        gate.resetForTests()
    }

    func testCameraGateBlocksEvenWithInternetAndCancelsPending() {
        let fake = FakeTask()
        gate.setValidInternetForTests(true)
        gate.setCameraIPv4PathReadyForTests(false)
        gate.setCameraSessionActive(false)
        gate.register(fake)
        XCTAssertFalse(gate.shouldBlockUpload)
        gate.setCameraSessionActive(true)
        XCTAssertTrue(gate.shouldBlockUpload)
        XCTAssertTrue(fake.cancelled)
        gate.setCameraSessionActive(false)
        gate.setCameraIPv4PathReadyForTests(true)
        XCTAssertTrue(gate.shouldBlockUpload)
    }

    func testHostIsolationRejectsNonDSNHosts() {
        let dsnHost = "o0.ingest.sentry.io"
        let allowed = URL(string: "https://o0.ingest.sentry.io/api/0/envelope/")!
        let other = URL(string: "https://example.com/ingest")!
        XCTAssertTrue(ReliabilityReportingHostPolicy.allows(allowed, dsnHost: dsnHost))
        XCTAssertFalse(ReliabilityReportingHostPolicy.allows(other, dsnHost: dsnHost))
        XCTAssertEqual(
            ReliabilityReportingNetwork.decision(for: other, dsnHost: dsnHost, gate: gate),
            .rejectHost)
        gate.setCameraSessionActive(true)
        XCTAssertEqual(
            ReliabilityReportingNetwork.decision(for: allowed, dsnHost: dsnHost, gate: gate),
            .blockCameraPath)
        XCTAssertEqual(
            ReliabilityReportingNetwork.retentionError(for: .blockCameraPath).code,
            URLError.notConnectedToInternet)
    }

    func testBackoffGrowsWithJitterBound() {
        let first = ReliabilityReportingBackoff.delaySeconds(attempt: 0, jitter: 0)
        let later = ReliabilityReportingBackoff.delaySeconds(attempt: 5, jitter: 1)
        XCTAssertGreaterThan(later, first)
        XCTAssertLessThanOrEqual(later, 30)
    }

    func testAutomaticOptOutDoesNotCancelManualReportButCameraGateDoes() {
        let gate = ReliabilityReportingGate(cameraIPv4Prefix: "192.168.2.")
        gate.setCameraIPv4PathReadyForTests(false)
        let manual = ManualCancellationProbe()
        gate.register(manual)
        gate.cancelPending(includeIndependent: false)
        XCTAssertFalse(manual.cancelled)
        gate.setCameraSessionActive(true)
        XCTAssertTrue(manual.cancelled)
    }

    func testReceiptsRefuseIDsThatLeaveTheReceiptsDirectory() throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("opc-receipts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let outside = cacheRoot.appendingPathComponent("escape.json")
        for id in ["../escape", "..", "a/b", "a\\b", "receipts/../../escape"] {
            ReliabilityReportingReceipts.store(
                ReliabilityReportingReceipt(
                    incidentID: id, eventID: "e", state: .queued, updatedAt: Date()),
                root: cacheRoot)
            XCTAssertNil(ReliabilityReportingReceipts.file(incidentID: id, root: cacheRoot), id)
            XCTAssertNil(ReliabilityReportingReceipts.load(incidentID: id, root: cacheRoot), id)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(ReliabilityReportingReceipts.loadAll(root: cacheRoot).isEmpty)
        try Data(#"{"incidentID":"x","eventID":"e","state":"queued","updatedAt":0}"#.utf8)
            .write(to: outside)
        XCTAssertNil(ReliabilityReportingReceipts.load(incidentID: "../escape", root: cacheRoot))
        // A UUID or session ID behaves as before: one `<id>.json` under receipts.
        for id in ["12c2d058-d584-4270-9aa2-eca08bf20986", "session-12c2d058d58442709aa2eca08bf20986"] {
            ReliabilityReportingReceipts.store(
                ReliabilityReportingReceipt(
                    incidentID: id, eventID: "e", state: .queued, updatedAt: Date()),
                root: cacheRoot)
            XCTAssertEqual(
                ReliabilityReportingReceipts.file(incidentID: id, root: cacheRoot),
                ReliabilityReportingReceipts.directory(root: cacheRoot)
                    .appendingPathComponent("\(id).json"))
            XCTAssertEqual(
                ReliabilityReportingReceipts.load(incidentID: id, root: cacheRoot)?.incidentID, id)
        }
    }

    private func envelope(eventID: String, trailer: String = "payload") -> Data {
        Data(
            "{\"event_id\":\"\(eventID)\",\"sent_at\":\"2026-09-14T00:00:00Z\"}\n{\"type\":\"event\"}\n\(trailer)\n"
                .utf8)
    }
}

private final class FakeTask: ReliabilityReportingCancellable {
    var cancelled = false
    func cancel() { cancelled = true }
}

private final class ManualCancellationProbe: ReliabilityReportingCancellable {
    var independentOfAutomaticConsent: Bool { true }
    var cancelled = false
    func cancel() { cancelled = true }
}
