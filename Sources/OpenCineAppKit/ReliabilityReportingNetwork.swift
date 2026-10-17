import Foundation
import zlib

// The network policy of an app's opt-in crash and incident reporting, without the reporting SDK:
// the camera-path upload gate, the DSN host policy, the forward decision, the envelope event ID
// and the retry backoff. The app keeps the SDK; `ReliabilityReportingURLProtocol` applies this
// policy to the SDK's own URLSession. Kotlin mirror: `appkit/diagnostics/ReliabilityReportingNetwork.kt`.

/// Upload gate: no report leaves while a camera path is held or the camera's IPv4 path is up,
/// including when cellular internet is also available. `cameraIPv4Prefix` is the camera
/// network's address prefix, supplied by the app; nil when the camera's network shares its
/// prefix with ordinary home networks, so only a held camera path holds reports back.
public final class ReliabilityReportingGate: @unchecked Sendable {
    public let cameraIPv4Prefix: String?

    private let lock = NSLock()
    private var cameraPathHolders = Set<UInt64>()
    private var nextCameraPathHolder: UInt64 = 0
    private var ipv4Override: Bool?
    private var validInternet = true
    private var pending: [ReliabilityReportingCancellable] = []

    public init(cameraIPv4Prefix: String?) {
        self.cameraIPv4Prefix = cameraIPv4Prefix
    }

    /// A connection owner holds the camera path (``beginCameraPath(onClear:)``).
    public var isCameraSessionActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cameraPathHolders.isEmpty
    }

    /// Blocks SDK upload while a camera path is held or the camera IPv4 path is up,
    /// including when cellular internet is also available.
    public var shouldBlockUpload: Bool {
        lock.lock()
        let session = !cameraPathHolders.isEmpty
        let override = ipv4Override
        lock.unlock()
        let ipv4 = override ?? cameraIPv4Prefix.map { Self.cameraIPv4PathReady(prefix: $0) } ?? false
        return session || ipv4
    }

    public var hasValidInternet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return validInternet
    }

    /// Holds the camera path until the lease ends and cancels uploads in flight. Every connection
    /// owner takes its own lease at its connect attempt and ends it when it retires, so a stale
    /// owner ending late never reopens a successor's hold. `onClear` runs when the last lease ends.
    public func beginCameraPath(onClear: @escaping @Sendable () -> Void = {})
        -> ReliabilityCameraPathLease
    {
        lock.lock()
        nextCameraPathHolder += 1
        let holder = nextCameraPathHolder
        cameraPathHolders.insert(holder)
        let toCancel = pending
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
        for task in toCancel { task.cancel() }
        return ReliabilityCameraPathLease { [self] in
            lock.lock()
            let cleared = cameraPathHolders.remove(holder) != nil && cameraPathHolders.isEmpty
            lock.unlock()
            if cleared { onClear() }
        }
    }

    public func setCameraIPv4PathReadyForTests(_ ready: Bool?) {
        lock.lock()
        ipv4Override = ready
        lock.unlock()
        if ready == true {
            cancelPending()
        }
    }

    public func setValidInternetForTests(_ ready: Bool) {
        lock.lock()
        validInternet = ready
        lock.unlock()
    }

    public func register(_ task: ReliabilityReportingCancellable) {
        lock.lock()
        pending.append(task)
        let blockNow = !cameraPathHolders.isEmpty || (ipv4Override ?? false)
        lock.unlock()
        if blockNow || shouldBlockUpload { task.cancel() }
    }

    public func unregister(_ task: ReliabilityReportingCancellable) {
        lock.lock()
        pending.removeAll { $0 === task }
        lock.unlock()
    }

    public func cancelPending(includeIndependent: Bool = true) {
        lock.lock()
        let toCancel = pending.filter { includeIndependent || !$0.independentOfAutomaticConsent }
        pending.removeAll { includeIndependent || !$0.independentOfAutomaticConsent }
        lock.unlock()
        for task in toCancel { task.cancel() }
    }

    public func resetForTests() {
        lock.lock()
        cameraPathHolders.removeAll()
        ipv4Override = false
        validInternet = true
        let toCancel = pending
        pending.removeAll()
        lock.unlock()
        for task in toCancel { task.cancel() }
    }

    /// Whether an IPv4 interface address starts with `prefix` (the camera network is up).
    public static func cameraIPv4PathReady(prefix: String) -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return false }
        defer { freeifaddrs(list) }
        var cursor = list
        while let iface = cursor {
            if let addr = iface.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let length = socklen_t(
                    max(Int(addr.pointee.sa_len), MemoryLayout<sockaddr_in>.size))
                if getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    == 0
                {
                    let ip = String(cString: host)
                    if ip.hasPrefix(prefix) { return true }
                }
            }
            cursor = iface.pointee.ifa_next
        }
        return false
    }
}

/// One connection owner's hold on the camera path, from its connect attempt (recovery included)
/// until it retires. Ending it again does nothing.
public final class ReliabilityCameraPathLease: @unchecked Sendable {
    private let lock = NSLock()
    private var release: (@Sendable () -> Void)?

    init(release: @escaping @Sendable () -> Void) {
        self.release = release
    }

    public var isEnded: Bool { lock.withLock { release == nil } }

    public func end() {
        let release = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { self.release = nil }
            return self.release
        }
        release?()
    }
}

public protocol ReliabilityReportingCancellable: AnyObject {
    func cancel()
    /// Manual operator reports keep transmitting after automatic-SDK opt-out.
    var independentOfAutomaticConsent: Bool { get }
}

extension ReliabilityReportingCancellable {
    public var independentOfAutomaticConsent: Bool { false }
}

extension URLSessionTask: ReliabilityReportingCancellable {}

public enum ReliabilityReportingHostPolicy {
    public static func host(fromDSN dsn: String) -> String? {
        URL(string: dsn)?.host
    }

    public static func allows(_ url: URL, dsnHost: String?) -> Bool {
        guard let host = url.host, !host.isEmpty else { return false }
        guard url.scheme?.lowercased() == "https" else { return false }
        if let dsnHost, host.caseInsensitiveCompare(dsnHost) == .orderedSame {
            return true
        }
        return false
    }
}

public enum ReliabilityReportingLoadDecision: Equatable, Sendable {
    case forward
    case blockCameraPath
    case rejectHost
    case noInternet
}

public enum ReliabilityReportingNetwork {
    public static func decision(
        for url: URL?,
        dsnHost: String?,
        gate: ReliabilityReportingGate
    ) -> ReliabilityReportingLoadDecision {
        guard let url else { return .rejectHost }
        if gate.shouldBlockUpload { return .blockCameraPath }
        guard ReliabilityReportingHostPolicy.allows(url, dsnHost: dsnHost) else {
            return .rejectHost
        }
        if !gate.hasValidInternet { return .noInternet }
        return .forward
    }

    /// Fail the SDK request without an HTTP response so envelopes stay cached.
    public static func retentionError(for decision: ReliabilityReportingLoadDecision) -> URLError {
        switch decision {
        case .blockCameraPath, .noInternet, .forward:
            return URLError(.notConnectedToInternet)
        case .rejectHost:
            return URLError(.cannotFindHost)
        }
    }
}

/// Rejects hops off the DSN host so auth and attachments cannot follow a 3xx. `dsnHost` reads
/// the app's current DSN host at each redirect.
public final class ReliabilityReportingRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    private let dsnHost: @Sendable () -> String?

    public init(dsnHost: @escaping @Sendable () -> String?) {
        self.dsnHost = dsnHost
    }

    public static func shouldFollow(url: URL?, dsnHost: String?) -> Bool {
        guard let url else { return false }
        return ReliabilityReportingHostPolicy.allows(url, dsnHost: dsnHost)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if Self.shouldFollow(url: request.url, dsnHost: dsnHost()) {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }
}

public enum ReliabilityReportingEnvelopeID {
    public static let maxHeaderBytes = 16 * 1_024
    public static let maxBodyCopyBytes = 2 * 1_024 * 1_024

    public static func eventID(from request: URLRequest) -> String? {
        let encoding = request.value(forHTTPHeaderField: "Content-Encoding")
        let body: Data?
        if let data = request.httpBody, !data.isEmpty {
            body = data
        } else if let stream = request.httpBodyStream {
            body = readStream(stream, limit: maxBodyCopyBytes)
        } else {
            body = nil
        }
        return eventID(fromBody: body, contentEncoding: encoding)
    }

    public static func eventID(fromBody body: Data?, contentEncoding: String?) -> String? {
        guard let body, !body.isEmpty else { return nil }
        guard let header = envelopeHeaderLine(from: body, contentEncoding: contentEncoding) else {
            return nil
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: header) as? [String: Any],
            let raw = object["event_id"] as? String
        else { return nil }
        let hex = raw.filter(\.isHexDigit).lowercased()
        return hex.count == 32 ? hex : nil
    }

    public static func envelopeHeaderLine(from body: Data, contentEncoding: String?) -> Data? {
        let encoding = contentEncoding?.lowercased() ?? ""
        let gzipMagic = body.count >= 2 && body[0] == 0x1F && body[1] == 0x8B
        let treatAsGzip = encoding.contains("gzip") || (gzipMagic && encoding.isEmpty)
        let decoded: Data?
        if treatAsGzip {
            decoded = ReliabilityReportingGzip.inflateHeader(from: body, maxOutput: maxHeaderBytes)
        } else if body.count <= maxHeaderBytes {
            decoded = body
        } else {
            decoded = body.prefix(maxHeaderBytes)
        }
        guard let decoded, !decoded.isEmpty else { return nil }
        if let newline = decoded.firstIndex(of: 0x0A) {
            return decoded.prefix(upTo: newline)
        }
        return decoded.count < maxHeaderBytes ? decoded : nil
    }

    public static func readStream(_ stream: InputStream, limit: Int) -> Data? {
        if stream.streamStatus == .notOpen { stream.open() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        defer { stream.close() }
        while true {
            let n = stream.read(
                &buffer, maxLength: min(buffer.count, max(1, limit + 1 - data.count)))
            if n < 0 { return nil }
            if n == 0 { break }
            data.append(buffer, count: n)
            if data.count > limit { return nil }
        }
        return data
    }

    /// Copy stream bodies onto `httpBody` so parse does not consume the forwarded payload.
    public static func materialized(_ request: URLRequest) -> (URLRequest, Data?) {
        if let body = request.httpBody, !body.isEmpty {
            return (request, body)
        }
        guard let stream = request.httpBodyStream,
            let data = readStream(stream, limit: maxBodyCopyBytes)
        else {
            return (request, nil)
        }
        var copy = request
        copy.httpBodyStream = nil
        copy.httpBody = data
        return (copy, data)
    }
}

public enum ReliabilityReportingGzip {
    /// Inflate gzip until a newline or `maxOutput` bytes. Does not decode the rest of the envelope.
    public static func inflateHeader(from data: Data, maxOutput: Int) -> Data? {
        guard data.count >= 2, maxOutput > 0 else { return nil }
        var stream = z_stream()
        let initStatus = inflateInit2_(
            &stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        var output = Data()
        let status = data.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return Z_DATA_ERROR }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(min(data.count, Int(uInt.max)))
            var rc: Int32 = Z_OK
            while output.count < maxOutput && rc != Z_STREAM_END {
                let room = min(256, maxOutput - output.count)
                var buf = [UInt8](repeating: 0, count: room)
                rc = buf.withUnsafeMutableBytes { dest -> Int32 in
                    guard let outBase = dest.bindMemory(to: Bytef.self).baseAddress else {
                        return Z_MEM_ERROR
                    }
                    stream.next_out = outBase
                    stream.avail_out = uInt(room)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = room - Int(stream.avail_out)
                if produced > 0 {
                    output.append(contentsOf: buf.prefix(produced))
                    if output.contains(0x0A) { return Z_STREAM_END }
                }
                if rc == Z_BUF_ERROR { break }
                if rc != Z_OK && rc != Z_STREAM_END { return rc }
                if stream.avail_in == 0 { break }
            }
            return rc
        }
        if output.isEmpty { return nil }
        if status != Z_OK && status != Z_STREAM_END && !output.contains(0x0A) { return nil }
        return output
    }

    public static func deflateForTests(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var stream = z_stream()
        let initStatus = deflateInit2_(
            &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 16 + MAX_WBITS, 8, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else { return nil }
        defer { deflateEnd(&stream) }
        var output = Data()
        let rc = data.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return Z_DATA_ERROR }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(data.count)
            var status: Int32 = Z_OK
            while status != Z_STREAM_END {
                var buf = [UInt8](repeating: 0, count: 256)
                status = buf.withUnsafeMutableBytes { dest -> Int32 in
                    guard let outBase = dest.bindMemory(to: Bytef.self).baseAddress else {
                        return Z_MEM_ERROR
                    }
                    stream.next_out = outBase
                    stream.avail_out = 256
                    return deflate(&stream, Z_FINISH)
                }
                let produced = 256 - Int(stream.avail_out)
                if produced > 0 { output.append(contentsOf: buf.prefix(produced)) }
                if status != Z_OK && status != Z_STREAM_END { return status }
            }
            return status
        }
        guard rc == Z_STREAM_END, !output.isEmpty else { return nil }
        return output
    }
}

public enum ReliabilityReportingBackoff {
    public static func delaySeconds(attempt: Int, jitter: Double) -> TimeInterval {
        let exponent = Double(min(6, max(0, attempt)))
        let base = min(30, pow(2, exponent) * 0.5)
        let spread = min(1, max(0, jitter))
        return min(30, max(0.25, base * (0.7 + 0.6 * spread)))
    }
}
