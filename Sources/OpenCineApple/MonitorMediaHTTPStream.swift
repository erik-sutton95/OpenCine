#if os(macOS) || os(iOS)
import Foundation
import OpenCineMedia

public enum MonitorMediaHTTPError: Error, Equatable, Sendable {
    case status(Int), empty, backpressureLimit
}

/// Bounded native movie copying. The source supplies URL and optional known size; staging and
/// commit belong to the caller's owned sink. Each request owns its delegate/session and retires
/// them on completion/cancellation. Header length wins over the source hint. Reaching it ends
/// the stream without waiting for a camera server to close its response.
public final class MonitorMediaHTTPStream: @unchecked Sendable {
    // Immutable private configuration copy; individual request delegates own all mutable state.
    private let configuration: URLSessionConfiguration
    private let queuedByteLimit: Int
    public init(configuration: URLSessionConfiguration, queuedByteLimit: Int = 4 * 1024 * 1024) {
        precondition(queuedByteLimit > 0)
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.queuedByteLimit = queuedByteLimit
    }
    public func transfer(from url: URL, expectedByteCount: UInt64? = nil,
        into sink: any MediaByteSink) async throws -> MediaTransferReceipt {
        let request = MediaHTTPRead(configuration: configuration, queuedByteLimit: queuedByteLimit)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            request.start(url: url, expected: expectedByteCount)
            defer { request.cancel() }
            var written: UInt64 = 0
            var lengthObserved = false
            for try await chunk in request.stream {
                try Task.checkCancellation()
                if !lengthObserved, let progress = sink as? any MediaTransferProgressSink {
                    try await progress.expectedByteCount(request.expected)
                    lengthObserved = true
                }
                try await sink.write(chunk)
                written += UInt64(chunk.count)
                let expected = request.expected
                if let expected, written >= expected { break }
                request.consumed(chunk.count)
            }
            try Task.checkCancellation()
            guard written > 0 else { throw MonitorMediaHTTPError.empty }
            return .init(byteCount: written, expectedByteCount: request.expected)
        } onCancel: { request.cancel() }
    }
}

/// URLSession delegate callbacks and cancellation may arrive on different queues. The lock owns
/// their byte accounting and session lifetime; only the async consumer calls its external sink.
private final class MediaHTTPRead: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let configuration: URLSessionConfiguration
    private let queuedByteLimit: Int
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var closed = false
    private var networkFinished = false
    private var suspended = false
    private var queuedBytes = 0
    private var expectedBytes: UInt64?

    init(configuration: URLSessionConfiguration, queuedByteLimit: Int) {
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        stream = pair.stream; continuation = pair.continuation
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.queuedByteLimit = queuedByteLimit
        super.init()
    }
    var expected: UInt64? { lock.lock(); defer { lock.unlock() }; return expectedBytes }
    func start(url: URL, expected: UInt64?) {
        var request = URLRequest(url: url)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: request)
        lock.lock()
        let cancelled = closed
        if !cancelled {
            expectedBytes = expected.flatMap { $0 > 0 ? $0 : nil }
            self.session = session; self.task = task
        }
        lock.unlock()
        if cancelled { session.invalidateAndCancel() } else { task.resume() }
    }
    func cancel() { finish(throwing: CancellationError()) }
    private func finish(throwing error: (any Error)?) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let session = session; self.session = nil; task = nil
        lock.unlock()
        continuation.finish(throwing: error)
        session?.invalidateAndCancel()
    }
    func consumed(_ count: Int) {
        lock.lock()
        queuedBytes = max(0, queuedBytes - count)
        let resume = !closed && !networkFinished && suspended && queuedBytes == 0
        if resume { suspended = false }
        let task = resume ? task : nil
        lock.unlock()
        task?.resume()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode
        if let status, !(200...299).contains(status) {
            completionHandler(.cancel); finish(throwing: MonitorMediaHTTPError.status(status)); return
        }
        lock.lock()
        let active = !closed
        if response.expectedContentLength > 0 { expectedBytes = UInt64(response.expectedContentLength) }
        lock.unlock()
        completionHandler(active ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        let exceeded = data.count > queuedByteLimit - queuedBytes
        if !exceeded { queuedBytes += data.count }
        let pause = !suspended
        suspended = true
        lock.unlock()
        if exceeded { finish(throwing: MonitorMediaHTTPError.backpressureLimit); return }
        if pause { dataTask.suspend() }
        continuation.yield(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let active = !closed; networkFinished = true
        lock.unlock()
        guard active else { return }
        // Preserve the donor's positive-byte EOF policy. Explicit caller cancellation already
        // retired this request; its cancellation callback cannot masquerade as successful EOF.
        if (error as NSError?)?.code == NSURLErrorCancelled { continuation.finish() }
        else { continuation.finish(throwing: error) }
    }
}
#endif
