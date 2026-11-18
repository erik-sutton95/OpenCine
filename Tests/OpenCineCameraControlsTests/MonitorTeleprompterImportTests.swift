#if os(iOS) || os(macOS)
    import Foundation
    import MonitorPresentation
    import OpenCineAppKit
    import Testing

    @testable import OpenCineCameraControls

    @Suite(.timeLimit(.minutes(1)))
    @MainActor
    struct MonitorTeleprompterImportTests {
        @Test func unknownLengthDownloadEnforcesTheLimitBeforeEOFAndPreservesTheOfflineCopy()
            async throws
        {
            guard #available(macOS 14, *) else { return }
            let storage = try ScriptStorage()
            defer { storage.close() }
            let model = storage.model
            let exact = try ScriptResponse(
                bytes: Data(repeating: 97, count: TeleprompterScriptImport.maximumBytes), eof: true)
            defer { exact.close() }
            await model.load { try await exact.load() }.value
            #expect(model.candidate?.text.utf8.count == TeleprompterScriptImport.maximumBytes)
            #expect(model.script?.text == "Saved offline")
            model.cancelImport()

            let oversized = try ScriptResponse(
                bytes: Data(repeating: 97, count: TeleprompterScriptImport.maximumBytes + 1))
            defer { oversized.close() }
            await model.load { try await oversized.load() }.value
            await oversized.stopped.wait()
            #expect(model.error != nil && model.candidate == nil)
            #expect(model.script?.text == "Saved offline")
            #expect(
                MonitorTeleprompterModel(defaults: storage.defaults).script?.text == "Saved offline"
            )
        }

        @Test func cancellingAPendingNativeRequestRetiresItAndPreservesTheOfflineCopy() async throws
        {
            guard #available(macOS 14, *) else { return }
            let storage = try ScriptStorage()
            defer { storage.close() }
            let response = try ScriptResponse()
            defer { response.close() }
            let model = storage.model
            let task = model.load { try await response.load() }
            await response.started.wait()
            model.cancelImport()
            await task.value
            await response.stopped.wait()
            #expect(!model.loading && model.error == nil && model.candidate == nil)
            #expect(
                MonitorTeleprompterModel(defaults: storage.defaults).script?.text == "Saved offline"
            )
        }

        @Test(arguments: ["http", "credentials"])
        func unsafeRedirectsNeverOpenTheirDestinationOrReplaceSavedText(kind: String) async throws {
            guard #available(macOS 14, *) else { return }
            let storage = try ScriptStorage()
            defer { storage.close() }
            let destination = try ScriptResponse(
                bytes: Data("Replacement".utf8), eof: true,
                scheme: kind == "http" ? "http" : "https", credentials: kind == "credentials")
            defer { destination.close() }
            let source = try ScriptResponse(status: 302, redirect: destination.url)
            defer { source.close() }
            await storage.model.load { try await source.load() }.value
            #expect(!destination.started.isSignalled)
            #expect(storage.model.error != nil && storage.model.candidate == nil)
            #expect(
                MonitorTeleprompterModel(defaults: storage.defaults).script?.text == "Saved offline"
            )
        }

        @Test func allowedRedirectKeepsTheOriginalRefreshURLUntilExplicitAcceptance() async throws {
            guard #available(macOS 14, *) else { return }
            let storage = try ScriptStorage()
            defer { storage.close() }
            let destination = try ScriptResponse(
                bytes: Data("# Updated\n\n- First cue".utf8), eof: true)
            defer { destination.close() }
            let source = try ScriptResponse(status: 302, redirect: destination.url)
            defer { source.close() }
            await storage.model.load { try await source.load() }.value
            #expect(destination.started.isSignalled)
            #expect(storage.model.candidate?.text == "Updated\n\n• First cue")
            #expect(storage.model.candidate?.sourceURL == source.url)
            #expect(storage.model.script?.text == "Saved offline")
            storage.model.useCandidate()
            let restored = MonitorTeleprompterModel(defaults: storage.defaults)
            #expect(restored.script?.text == "Updated\n\n• First cue")
            #expect(restored.script?.sourceURL == source.url)
        }
    }

    @available(macOS 14, *)
    @MainActor
    private final class ScriptStorage {
        let domain = "teleprompter-import-test." + UUID().uuidString
        let defaults: UserDefaults
        let model: MonitorTeleprompterModel
        init() throws {
            defaults = try #require(UserDefaults(suiteName: domain))
            model = MonitorTeleprompterModel(defaults: defaults)
            model.previewPaste("Saved offline")
            model.useCandidate()
        }
        func close() { defaults.removePersistentDomain(forName: domain) }
    }

    // SIMULATED native HTTP callbacks. Every URL owns its response and lifecycle events.
    private final class ScriptResponse: Sendable {
        let url: URL
        let status: Int
        let bytes: Data
        let eof: Bool
        let redirect: URL?
        let started = ScriptHTTPEvent()
        let stopped = ScriptHTTPEvent()

        init(
            status: Int = 200, bytes: Data = Data(), eof: Bool = false, redirect: URL? = nil,
            scheme: String = "https", credentials: Bool = false
        ) throws {
            var components = URLComponents()
            components.scheme = scheme
            components.host = "teleprompter-import.invalid"
            components.path = "/" + UUID().uuidString + "/script.md"
            if credentials {
                components.user = "reader"
                components.password = "placeholder"
            }
            url = try #require(components.url)
            self.status = status
            self.bytes = bytes
            self.eof = eof
            self.redirect = redirect
            ScriptHTTPProtocol.responses.insert(self)
        }

        func load() async throws -> TeleprompterScript {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ScriptHTTPProtocol.self]
            return try await MonitorTeleprompterLoader.remote(url, configuration: configuration)
        }

        func close() { ScriptHTTPProtocol.responses.remove(url) }
    }

    private final class ScriptHTTPEvent: @unchecked Sendable {
        private let lock = NSLock()
        private var signalled = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        var isSignalled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return signalled
        }
        func signal() {
            lock.lock()
            signalled = true
            let pending = waiters
            waiters.removeAll()
            lock.unlock()
            for waiter in pending { waiter.resume() }
        }
        func wait() async {
            await withCheckedContinuation { waiter in
                lock.lock()
                if signalled {
                    lock.unlock()
                    waiter.resume()
                } else {
                    waiters.append(waiter)
                    lock.unlock()
                }
            }
        }
    }

    private final class ScriptResponses: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [URL: ScriptResponse] = [:]
        func insert(_ response: ScriptResponse) {
            lock.lock()
            values[response.url] = response
            lock.unlock()
        }
        func remove(_ url: URL) {
            lock.lock()
            values[url] = nil
            lock.unlock()
        }
        func value(_ url: URL) -> ScriptResponse? {
            lock.lock()
            defer { lock.unlock() }
            return values[url]
        }
    }

    private final class ScriptHTTPProtocol: URLProtocol, @unchecked Sendable {
        static let responses = ScriptResponses()
        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "teleprompter-import.invalid"
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let url = request.url, let fixture = Self.responses.value(url),
                let response = HTTPURLResponse(
                    url: url, statusCode: fixture.status,
                    httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/markdown"])
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
                return
            }
            fixture.started.signal()
            if let redirect = fixture.redirect {
                client?.urlProtocol(
                    self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !fixture.bytes.isEmpty { client?.urlProtocol(self, didLoad: fixture.bytes) }
            if fixture.eof { client?.urlProtocolDidFinishLoading(self) }
        }
        override func stopLoading() {
            if let url = request.url { Self.responses.value(url)?.stopped.signal() }
        }
    }
#endif
