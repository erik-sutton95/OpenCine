#if os(macOS) || os(iOS)
import Foundation
import OpenCineApple
import OpenCineMedia
import Testing

// SIMULATED HTTP server: each request owns an explicit fixture keyed by its unique URL. Tests
// drive response/data/EOF callbacks without sockets, clocks or process-wide product state.
private final class HTTPEvent: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() {
        lock.lock(); signalled = true; let pending = waiters; waiters.removeAll(); lock.unlock()
        for waiter in pending { waiter.resume() }
    }
    func wait() async {
        await withCheckedContinuation { waiter in
            lock.lock()
            if signalled { lock.unlock(); waiter.resume() }
            else { waiters.append(waiter); lock.unlock() }
        }
    }
}
private final class HTTPFixtures: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL: HTTPFixture] = [:]
    func insert(_ fixture: HTTPFixture) { lock.lock(); values[fixture.url] = fixture; lock.unlock() }
    func remove(_ url: URL) { lock.lock(); values[url] = nil; lock.unlock() }
    func value(_ url: URL) -> HTTPFixture? { lock.lock(); defer { lock.unlock() }; return values[url] }
}
private final class HTTPFixture: Sendable {
    let url = URL(string: "https://opencine-http.invalid/" + UUID().uuidString)!
    let status: Int, length: Int?, bytes: Data, eof: Bool
    let started = HTTPEvent(), stopped = HTTPEvent()
    init(status: Int = 200, length: Int? = nil, bytes: Data = Data(), eof: Bool = false) {
        self.status = status; self.length = length; self.bytes = bytes; self.eof = eof
        SimulatedHTTPProtocol.fixtures.insert(self)
    }
    func dispose() { SimulatedHTTPProtocol.fixtures.remove(url) }
    func stream(limit: Int = 4 * 1024 * 1024) -> MonitorMediaHTTPStream {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SimulatedHTTPProtocol.self]
        return MonitorMediaHTTPStream(configuration: configuration, queuedByteLimit: limit)
    }
}
private final class SimulatedHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let fixtures = HTTPFixtures()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "opencine-http.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let fixture = Self.fixtures.value(url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        fixture.started.signal()
        var headers = ["Content-Type": "application/octet-stream"]
        if let length = fixture.length { headers["Content-Length"] = String(length) }
        let response = HTTPURLResponse(url: url, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !fixture.bytes.isEmpty { client?.urlProtocol(self, didLoad: fixture.bytes) }
        if fixture.eof { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {
        if let url = request.url { Self.fixtures.value(url)?.stopped.signal() }
    }
}
private actor HTTPSink: MediaByteSink {
    var bytes = Data()
    func write(_ chunk: Data) { bytes.append(chunk) }
}

@Suite(.timeLimit(.minutes(1))) struct MonitorMediaHTTPStreamTests {
    @Test func headerLengthWinsAndClosesWithoutEOF() async throws {
        let fixture = HTTPFixture(length: 2, bytes: Data([1, 2])); defer { fixture.dispose() }
        let sink = HTTPSink()
        let receipt = try await fixture.stream().transfer(from: fixture.url, expectedByteCount: 9, into: sink)
        #expect(receipt == .init(byteCount: 2, expectedByteCount: 2))
        #expect(await sink.bytes == Data([1, 2]))
        await fixture.stopped.wait()
    }
    @Test func sourceHintStopsBodyWhenHeaderUnknown() async throws {
        let fixture = HTTPFixture(bytes: Data([3, 4])); defer { fixture.dispose() }
        let sink = HTTPSink()
        #expect(try await fixture.stream().transfer(from: fixture.url, expectedByteCount: 2, into: sink)
            == .init(byteCount: 2, expectedByteCount: 2))
        await fixture.stopped.wait()
    }
    @Test func positiveEOFDoesNotInventSizeOrRejectPartialReceipt() async throws {
        for hint: UInt64? in [nil, 9] {
            let fixture = HTTPFixture(bytes: Data([5, 6]), eof: true); defer { fixture.dispose() }
            #expect(try await fixture.stream().transfer(from: fixture.url, expectedByteCount: hint, into: HTTPSink())
                == .init(byteCount: 2, expectedByteCount: hint))
        }
    }
    @Test func emptyEOFIsRefused() async {
        let fixture = HTTPFixture(eof: true); defer { fixture.dispose() }
        await #expect(throws: MonitorMediaHTTPError.empty) {
            try await fixture.stream().transfer(from: fixture.url, into: HTTPSink())
        }
    }
    @Test func cancellationRetiresPendingReadAndItsNativeRequest() async {
        let fixture = HTTPFixture(); defer { fixture.dispose() }
        let sink = HTTPSink(), stream = fixture.stream()
        let task = Task { try await stream.transfer(from: fixture.url, into: sink) }
        await fixture.started.wait(); task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await fixture.stopped.wait()
        #expect(await sink.bytes.isEmpty)
    }
    @Test func refusedStatusAndOversizedChunkCannotPublishBytes() async {
        let refused = HTTPFixture(status: 403); defer { refused.dispose() }
        let sink = HTTPSink()
        await #expect(throws: MonitorMediaHTTPError.status(403)) {
            try await refused.stream().transfer(from: refused.url, into: sink)
        }
        let oversized = HTTPFixture(bytes: Data([1, 2, 3])); defer { oversized.dispose() }
        await #expect(throws: MonitorMediaHTTPError.backpressureLimit) {
            try await oversized.stream(limit: 2).transfer(from: oversized.url, into: sink)
        }
        #expect(await sink.bytes.isEmpty)
    }
}
#endif
