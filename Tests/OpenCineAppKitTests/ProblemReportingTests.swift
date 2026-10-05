import CoreGraphics
import Foundation
import ImageIO
import OpenCineAppKit
import UniformTypeIdentifiers
import XCTest

/// Moved from the iOS apps' ProblemReportingTests and ProblemReportImageTests. The apps' shared
/// gate and stored consent are instances here; the image fixture is drawn with CoreGraphics so
/// it also runs on the macOS test host.
@available(macOS 14, *) @MainActor final class ProblemReportingTests: XCTestCase {
    private let gate = ReliabilityReportingGate(cameraIPv4Prefix: "192.168.2.")
    private let consent = ReliabilityReportingConsent(
        defaults: UserDefaults(suiteName: UUID().uuidString)!)

    private func reporter(
        _ root: URL, dsn: String? = nil, configuration: URLSessionConfiguration? = nil,
        foreground: Bool = true
    ) -> ProblemReporting {
        ProblemReporting(
            host: TestDiagnostics.host, gate: gate, directory: root, dsnProvider: { dsn },
            sessionConfiguration: configuration, isForeground: { foreground })
    }

    func testExplicitManualSubmissionPersistsWithoutAutomaticConsentAndCanBeDiscarded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        consent.setOptedIn(false)
        gate.setCameraIPv4PathReadyForTests(true)
        defer { gate.setCameraIPv4PathReadyForTests(nil) }
        let reporter = reporter(root, dsn: "https://public@sentry.invalid/42")
        XCTAssertNil(reporter.pending)
        try reporter.submit(message: "Synthetic test report", email: "", diagnostics: nil)
        XCTAssertFalse(consent.isOptedIn)
        XCTAssertNotNil(reporter.pending)
        XCTAssertThrowsError(try reporter.submit(message: "Second", email: "", diagnostics: nil))
        let restored = self.reporter(root)
        XCTAssertEqual(restored.pending?.id, reporter.pending?.id)
        try restored.discard()
        XCTAssertNil(self.reporter(root).pending)
    }

    func testFeedbackSchemaOmitsContactAndAttachmentsUnlessProvided() throws {
        let data = try ProblemReporting.envelope(
            host: TestDiagnostics.host, id: "123", message: "Synthetic test", email: "",
            diagnostics: nil, date: Date())
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        let header = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        XCTAssertEqual(header["type"] as? String, "feedback")
        let event = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[2].utf8)) as? [String: Any])
        let contexts = try XCTUnwrap(event["contexts"] as? [String: Any])
        let feedback = try XCTUnwrap(contexts["feedback"] as? [String: Any])
        XCTAssertEqual(feedback["message"] as? String, "Synthetic test")
        XCTAssertNil(feedback["contact_email"])
        XCTAssertNil(event["user"])
        XCTAssertEqual(lines.count, 3)
    }

    func testExplicitEmailIsPreservedAndAttachmentIsBounded() throws {
        let data = try ProblemReporting.envelope(
            host: TestDiagnostics.host, id: "123", message: "Synthetic test",
            email: "reply@example.invalid",
            diagnostics: String(repeating: "a", count: 200_000), date: Date())
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("reply@example.invalid"))
        XCTAssertTrue(text.contains("diagnostics.txt"))
        XCTAssertLessThan(data.count, 34_000)
    }

    func testEndpointRejectsInvalidDestinationsAndRemovesUserInfo() {
        XCTAssertNil(ProblemReporting.endpoint(dsn: "http://key@sentry.invalid/42"))
        let url = ProblemReporting.endpoint(dsn: "https://key@sentry.invalid/prefix/42")
        XCTAssertEqual(url?.path, "/prefix/api/42/envelope")
        XCTAssertNil(url?.user)
        XCTAssertEqual(url?.host, "sentry.invalid")
    }

    func testRetryAfterIsRespected() {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.invalid")!, statusCode: 429, httpVersion: nil,
            headerFields: ["Retry-After": "900"])!
        XCTAssertEqual(ProblemReporting.retryDelay(response: response, attempts: 1), 900)
    }

    func testHTTPAcceptanceClearsQueueWithoutEnablingAutomaticReports() async throws {
        try await verifyHTTPResponse(code: 200, shouldRemainQueued: false)
    }

    func testServerFailureKeepsOriginalReportForRetry() async throws {
        try await verifyHTTPResponse(code: 503, shouldRemainQueued: true)
    }

    private func verifyHTTPResponse(code: Int, shouldRemainQueued: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        consent.setOptedIn(false)
        gate.setCameraIPv4PathReadyForTests(false)
        gate.setValidInternetForTests(true)
        defer {
            try? FileManager.default.removeItem(at: root)
            gate.setCameraIPv4PathReadyForTests(nil)
        }
        ManualReportHTTPStub.code = code
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ManualReportHTTPStub.self]
        let reporter = reporter(
            root, dsn: "https://public@sentry.invalid/42", configuration: configuration)
        try reporter.submit(message: "Synthetic transport test", email: "", diagnostics: nil)
        let id = reporter.pending?.id
        for _ in 0..<100 {
            if !reporter.status.hasPrefix("Sending") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(consent.isOptedIn)
        if shouldRemainQueued {
            XCTAssertEqual(reporter.pending?.id, id)
            XCTAssertGreaterThan(try XCTUnwrap(reporter.pending?.nextAttempt), Date())
            XCTAssertEqual(self.reporter(root).pending?.id, id)
        } else {
            XCTAssertNil(reporter.pending)
            XCTAssertTrue(reporter.status.hasPrefix("Report sent"))
            XCTAssertNil(self.reporter(root).pending)
        }
    }

    func testExpiredReportIsRemovedAfterRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reporter = reporter(root, dsn: "https://public@sentry.invalid/42", foreground: false)
        try reporter.submit(message: "Synthetic expiry test", email: "", diagnostics: nil)
        let restored = self.reporter(root, foreground: false)
        restored.tick(now: Date().addingTimeInterval(ProblemReporting.lifetime + 1))
        XCTAssertNil(restored.pending)
        XCTAssertNil(self.reporter(root).pending)
        XCTAssertTrue(restored.status.contains("expired"))
    }

    func testNormalizationRemovesMetadataAndBoundsPixels() throws {
        let raw = try fixture()
        let originalSource = try XCTUnwrap(CGImageSourceCreateWithData(raw as CFData, nil))
        let originalProperties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(originalSource, 0, nil) as? [String: Any])
        XCTAssertNotNil(originalProperties[kCGImagePropertyGPSDictionary as String])
        let normalized = try ProblemReportImage.prepare(raw)
        XCTAssertLessThanOrEqual(normalized.jpeg.count, ProblemReportImage.maximumBytes)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(normalized.jpeg as CFData, nil))
        let props = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertNil(props[kCGImagePropertyGPSDictionary as String])
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        XCTAssertTrue(
            Set(exif.keys).isSubset(of: ["ColorSpace", "PixelXDimension", "PixelYDimension"]))
        XCTAssertNil(exif[kCGImagePropertyExifUserComment as String])
        XCTAssertLessThanOrEqual(
            props[kCGImagePropertyPixelWidth as String] as? Int ?? Int.max, 1600)
        XCTAssertLessThanOrEqual(
            props[kCGImagePropertyPixelHeight as String] as? Int ?? Int.max, 1600)
    }

    func testCorruptImageIsRejected() {
        XCTAssertThrowsError(try ProblemReportImage.prepare(Data("not an image".utf8)))
    }

    func testImagesPersistInManualEnvelopeAndDiscardTogether() throws {
        let image = try ProblemReportImage.prepare(fixture())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reporter = reporter(root, dsn: "https://public@sentry.invalid/42", foreground: false)
        try reporter.submit(message: "Image test", email: "", diagnostics: nil, images: [image])
        let queued = try XCTUnwrap(reporter.pending?.envelope)
        XCTAssertNotNil(queued.range(of: Data("image-1.jpg".utf8)))
        XCTAssertNotNil(queued.range(of: image.jpeg))
        let restored = self.reporter(root, foreground: false)
        XCTAssertEqual(restored.pending?.envelope, queued)
        try restored.discard()
        XCTAssertNil(self.reporter(root).pending)
        XCTAssertThrowsError(
            try ProblemReporting.envelope(
                host: TestDiagnostics.host, id: "test", message: "test", email: "",
                diagnostics: nil, date: Date(), images: Array(repeating: image, count: 4)))
    }

    /// A 2000 x 1200 blue JPEG carrying GPS and an EXIF user comment.
    private func fixture() throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 2000, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2000, height: 1200))
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(
            destination, try XCTUnwrap(context.makeImage()),
            [
                kCGImagePropertyGPSDictionary: [
                    kCGImagePropertyGPSLatitude: 12.0, kCGImagePropertyGPSLatitudeRef: "N",
                ],
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifUserComment: "Synthetic private metadata"
                ],
            ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}

/// No socket is opened by these transport tests.
private final class ManualReportHTTPStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var code = 200
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "sentry.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
