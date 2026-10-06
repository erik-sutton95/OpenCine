import Foundation

/// The reporting SDK's forwarding side: the app's reporting runtime and the session that forwards
/// the requests ``ReliabilityReportingURLProtocol`` admits, which refuses redirects off the DSN
/// host. One per app, beside its `ReliabilityReporting`.
public final class ReliabilityReportingForwarder: @unchecked Sendable {
    public let reporting: ReliabilityReporting
    public let redirectGuard: ReliabilityReportingRedirectGuard
    private let lock = NSLock()
    private var sessionStorage: URLSession

    public init(reporting: ReliabilityReporting) {
        self.reporting = reporting
        let redirectGuard = ReliabilityReportingRedirectGuard { [reporting] in reporting.dsnHost }
        self.redirectGuard = redirectGuard
        sessionStorage = Self.makeForwardingSession(redirectGuard: redirectGuard)
    }

    /// Where admitted requests go. Tests replace it.
    public var session: URLSession {
        get { lock.withLock { sessionStorage } }
        set { lock.withLock { sessionStorage = newValue } }
    }

    public static func makeForwardingSession(
        redirectGuard: ReliabilityReportingRedirectGuard
    ) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config, delegate: redirectGuard, delegateQueue: nil)
    }
}

/// Applies the reporting network policy (consent, camera-path gate, DSN host, envelope event ID)
/// to the reporting SDK's own URLSession: refused requests fail without an HTTP response so the
/// SDK keeps them cached. Never registered globally. A URLProtocol is registered by class, so each
/// app subclasses it once and names its ``forwarder``; ``makeSDKSession()`` on that subclass is the
/// session the app hands the SDK.
open class ReliabilityReportingURLProtocol: URLProtocol, @unchecked Sendable {
    /// The app's forwarder. Every subclass overrides it.
    open class var forwarder: ReliabilityReportingForwarder {
        preconditionFailure("Subclass ReliabilityReportingURLProtocol and name the app's forwarder")
    }

    private var forwardingTask: TaskBox?
    private var pendingEventID: String?

    override open class func canInit(with request: URLRequest) -> Bool { true }

    override open class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override open func startLoading() {
        let reporting = type(of: self).forwarder.reporting
        let consent = reporting.consent
        let gate = reporting.gate
        guard consent.isOptedIn else {
            failWithoutResponse(URLError(.notConnectedToInternet))
            return
        }
        let decision = ReliabilityReportingNetwork.decision(
            for: request.url, dsnHost: reporting.dsnHost, gate: gate)
        if decision != .forward {
            failWithoutResponse(ReliabilityReportingNetwork.retentionError(for: decision))
            return
        }
        let materialized = ReliabilityReportingEnvelopeID.materialized(request)
        if request.httpBodyStream != nil, materialized.1 == nil {
            failWithoutResponse(URLError(.dataLengthExceedsMaximum))
            return
        }
        pendingEventID = ReliabilityReportingEnvelopeID.eventID(
            fromBody: materialized.1,
            contentEncoding: request.value(forHTTPHeaderField: "Content-Encoding"))
        let box = TaskBox()
        let dataTask = type(of: self).forwarder.session.dataTask(with: materialized.0) {
            [weak self, weak box] data, response, error in
            guard let self else { return }
            if let box { gate.unregister(box) }
            if gate.shouldBlockUpload || !consent.isOptedIn {
                self.failWithoutResponse(URLError(.notConnectedToInternet))
                return
            }
            if let error, (error as NSError).code == NSURLErrorCancelled {
                self.failWithoutResponse(URLError(.notConnectedToInternet))
                return
            }
            if response == nil {
                self.failWithoutResponse(error ?? URLError(.notConnectedToInternet))
                return
            }
            if let response {
                self.client?.urlProtocol(
                    self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if let http = response as? HTTPURLResponse,
                    (200..<300).contains(http.statusCode),
                    let eventID = self.pendingEventID
                {
                    reporting.noteTransportSuccess(eventID: eventID)
                }
            }
            if let data { self.client?.urlProtocol(self, didLoad: data) }
            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
            } else {
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
        box.inner = dataTask
        forwardingTask = box
        gate.register(box)
        if gate.shouldBlockUpload || !consent.isOptedIn {
            box.cancel()
            failWithoutResponse(URLError(.notConnectedToInternet))
            return
        }
        dataTask.resume()
    }

    override open func stopLoading() {
        forwardingTask?.cancel()
        if let forwardingTask { type(of: self).forwarder.reporting.gate.unregister(forwardingTask) }
        forwardingTask = nil
    }

    private func failWithoutResponse(_ error: Error) {
        client?.urlProtocol(self, didFailWithError: error)
    }

    /// The session the app hands the SDK: requests go through this class (the app's subclass).
    public class func makeSDKSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [self]
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }

    private final class TaskBox: ReliabilityReportingCancellable, @unchecked Sendable {
        var inner: URLSessionDataTask?
        func cancel() { inner?.cancel() }
    }
}
