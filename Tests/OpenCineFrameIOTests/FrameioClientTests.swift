import Foundation
import Testing

@testable import OpenCineFrameIO

// Fixtures: a scripted HTTP transport, in-memory token storage, a fixed clock and a recorded
// pause. Nothing touches the network, a keychain or the wall clock.

private let config = FrameioConfiguration(
    clientID: "test-client-id", redirectURI: "adobe+abc123://adobeid/test-client-id")
private let epoch = Date(timeIntervalSinceReferenceDate: 800_000_000)

actor FakeTransport: FrameioHTTPTransport {
    private(set) var sent: [FrameioAPIRequest] = []
    private let route: @Sendable (FrameioAPIRequest, [FrameioAPIRequest]) -> FrameioHTTPResponse

    init(
        route: @escaping @Sendable (FrameioAPIRequest, [FrameioAPIRequest]) -> FrameioHTTPResponse
    ) {
        self.route = route
    }

    func send(_ request: FrameioAPIRequest) async throws -> FrameioHTTPResponse {
        let prior = sent
        sent.append(request)
        return route(request, prior)
    }
}

final class MemoryTokens: FrameioTokenStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: StoredFrameioToken?

    init(_ stored: StoredFrameioToken? = nil) { self.stored = stored }

    func load() -> StoredFrameioToken? { lock.withLock { stored } }
    func save(_ stored: StoredFrameioToken) { lock.withLock { self.stored = stored } }
    func clear() { lock.withLock { stored = nil } }
}

actor Recorder<Value: Sendable> {
    private(set) var values: [Value] = []
    func append(_ value: Value) { values.append(value) }
}

private func json(_ text: String, status: Int = 200) -> FrameioHTTPResponse {
    FrameioHTTPResponse(statusCode: status, body: Data(text.utf8))
}

private func freshToken(access: String = "AT", refresh: String? = "RT") -> StoredFrameioToken {
    StoredFrameioToken(
        token: FrameioToken(
            accessToken: access, refreshToken: refresh, expiresIn: 3600, tokenType: "bearer"),
        receivedAt: epoch)
}

private func client(
    _ transport: FakeTransport, tokens: MemoryTokens = MemoryTokens(freshToken()),
    now: Date = epoch, pauses: Recorder<Duration> = Recorder()
) -> FrameioClient {
    FrameioClient(
        config: config, transport: transport, tokens: tokens, now: { now },
        pause: { await pauses.append($0) })
}

private func temporaryFile(_ bytes: [UInt8]) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("frameio-\(UUID().uuidString).mov")
    try Data(bytes).write(to: url)
    return url
}

private let createdTwoParts = """
    { "data": { "id": "file-1", "media_type": "video/quicktime", "upload_urls": [
        { "size": 3, "url": "https://s3.example/part1" },
        { "size": 2, "url": "https://s3.example/part2" } ] } }
    """

@Suite struct FrameioClientTests {
    @Test func uploadPutsEachPartThenPollsUntilConfirmed() async throws {
        let transport = FakeTransport { request, prior in
            switch (request.method, request.url.lastPathComponent) {
            case (.post, "local_upload"): return json(createdTwoParts)
            case (.put, _): return FrameioHTTPResponse(statusCode: 200)
            case (.get, "status"):
                let polls = prior.filter { $0.url.lastPathComponent == "status" }.count
                return json(#"{ "data": { "id": "file-1", "upload_complete": \#(polls > 0) } }"#)
            default: return json("{}", status: 404)
            }
        }
        let pauses = Recorder<Duration>()
        let progress = Recorder<Double>()
        let file = try temporaryFile([1, 2, 3, 4, 5])
        defer { try? FileManager.default.removeItem(at: file) }

        let fileID = try await client(transport, pauses: pauses).upload(
            fileURL: file, name: "C0001.MOV", mediaType: "video/mp4", fileSize: 5,
            accountID: "account-1", folderID: "folder-1"
        ) { await progress.append($0) }

        #expect(fileID == "file-1")
        let sent = await transport.sent
        #expect(sent.map(\.method) == [.post, .put, .put, .get, .get])
        #expect(
            sent[0].url.absoluteString
                == "https://api.frame.io/v4/accounts/account-1/folders/folder-1/files/local_upload")
        #expect(sent[0].headers["Authorization"] == "Bearer AT")
        // Parts carry their own bytes, Frame.io's media type and no bearer token.
        #expect(sent[1].body == Data([1, 2, 3]))
        #expect(sent[2].body == Data([4, 5]))
        #expect(sent[1].headers["Content-Type"] == "video/quicktime")
        #expect(sent[1].headers["x-amz-acl"] == "private")
        #expect(sent[1].headers["Authorization"] == nil)
        #expect(sent[3].headers["Authorization"] == "Bearer AT")
        #expect(await pauses.values == [.seconds(2)])
        let fractions = await progress.values
        #expect(fractions.first == 0.05)
        #expect(fractions.last == 1.0)
        #expect(fractions == fractions.sorted(), "progress never goes backwards")
    }

    @Test func uploadRejectsAPlanThatDoesNotMatchTheFileBeforeSendingBytes() async throws {
        let transport = FakeTransport { _, _ in json(createdTwoParts) }
        let file = try temporaryFile([1, 2, 3, 4, 5, 6])
        defer { try? FileManager.default.removeItem(at: file) }

        await #expect(throws: FrameioError.unexpectedFileSize) {
            _ = try await client(transport).upload(
                fileURL: file, name: "C0001.MOV", mediaType: "video/mp4", fileSize: 6,
                accountID: "a", folderID: "f")
        }
        #expect(await transport.sent.map(\.method) == [.post])
    }

    @Test func uploadGivesUpWhenFrameioNeverConfirms() async throws {
        let transport = FakeTransport { request, _ in
            switch request.method {
            case .post: json(createdTwoParts)
            case .put: FrameioHTTPResponse(statusCode: 200)
            case .get: json(#"{ "data": { "id": "file-1", "upload_complete": false } }"#)
            }
        }
        let pauses = Recorder<Duration>()
        let file = try temporaryFile([1, 2, 3, 4, 5])
        defer { try? FileManager.default.removeItem(at: file) }

        await #expect(throws: FrameioError.uploadIncomplete) {
            _ = try await client(transport, pauses: pauses).upload(
                fileURL: file, name: "C0001.MOV", mediaType: "video/mp4", fileSize: 5,
                accountID: "a", folderID: "f")
        }
        #expect(await pauses.values.count == FrameioClient.statusPollAttempts)
    }

    @Test func httpFailureSurfacesStatusAndBody() async {
        let transport = FakeTransport { _, _ in json("nope", status: 403) }
        await #expect(throws: FrameioError.http(403, "nope")) {
            _ = try await client(transport).accounts()
        }
    }

    @Test func missingTokenFailsWithoutAnyRequest() async {
        let transport = FakeTransport { _, _ in json("{}") }
        await #expect(throws: FrameioError.notConnected) {
            _ = try await client(transport, tokens: MemoryTokens()).accounts()
        }
        #expect(await transport.sent.isEmpty)
    }

    @Test func nearExpiryRefreshesFirstAndKeepsTheRefreshTokenIMSOmitted() async throws {
        let transport = FakeTransport { request, _ in
            request.url.host == "ims-na1.adobelogin.com"
                ? json(#"{ "access_token": "AT2", "expires_in": 3600, "token_type": "bearer" }"#)
                : json(#"{ "data": [ { "id": "acc", "display_name": "Me" } ] }"#)
        }
        let tokens = MemoryTokens(freshToken())
        // 30 s before expiry: inside the 60 s early-refresh window.
        let later = epoch.addingTimeInterval(3570)

        let accounts = try await client(transport, tokens: tokens, now: later).accounts()

        #expect(accounts.map(\.id) == ["acc"])
        let sent = await transport.sent
        #expect(sent.count == 2)
        #expect(String(decoding: sent[0].body ?? Data(), as: UTF8.self).contains("refresh_token=RT"))
        #expect(sent[1].headers["Authorization"] == "Bearer AT2")
        #expect(tokens.load()?.token.accessToken == "AT2")
        #expect(tokens.load()?.token.refreshToken == "RT")
        #expect(tokens.load()?.receivedAt == later)
    }

    /// A2-57: the one listing every app's popup offers: the first account's first workspace.
    @Test func firstWorkspaceProjectsListsTheFirstAccountsFirstWorkspace() async throws {
        let transport = FakeTransport { request, _ in
            let path = request.url.path
            if path.hasSuffix("/accounts") {
                return json(#"{ "data": [ { "id": "acc-1" }, { "id": "acc-2" } ] }"#)
            }
            if path.hasSuffix("/workspaces") {
                return json(#"{ "data": [ { "id": "ws-1", "name": "Main" }, { "id": "ws-2", "name": "Other" } ] }"#)
            }
            return json(#"{ "data": [ { "id": "p-1", "name": "Shoot", "root_folder_id": "f-1" } ] }"#)
        }
        let listing = try await client(transport).firstWorkspaceProjects()
        #expect(listing.accountID == "acc-1" && listing.workspaceID == "ws-1" && listing.workspaceName == "Main")
        #expect(listing.projects.map(\.id) == ["p-1"])
        let destination = try #require(FrameioDestination(project: listing.projects[0], in: listing))
        #expect(destination.folderID == "f-1" && destination.projectName == "Shoot")
        #expect(await transport.sent.count == 3)
    }

    @Test func freshTokenIsUsedWithoutRefresh() async throws {
        let transport = FakeTransport { _, _ in json(#"{ "data": { "id": "u1" } }"#) }
        let user = try await client(transport, now: epoch.addingTimeInterval(3000)).currentUser()
        #expect(user.id == "u1")
        #expect(await transport.sent.count == 1)
    }

    @Test func completeSignInStoresTheTokenWithTheInjectedClock() async throws {
        let transport = FakeTransport { _, _ in
            json(#"{ "access_token": "AT", "refresh_token": "RT", "expires_in": 60, "token_type": "bearer" }"#)
        }
        let tokens = MemoryTokens()
        try await client(transport, tokens: tokens).completeSignIn(code: "c", verifier: "v")
        #expect(tokens.load()?.receivedAt == epoch)
        #expect(tokens.load()?.token.refreshToken == "RT")
        #expect(await transport.sent.first?.headers["Authorization"] == nil)
    }

    /// Both apps wrote this shape to their keychains before the move; it must still decode or
    /// every operator would have to sign in again.
    @Test func savedSignInFromTheAppClientsStillDecodes() throws {
        let legacy = """
            {"token":{"access_token":"AT","refresh_token":"RT","expires_in":3600,\
            "token_type":"bearer"},"receivedAt":800000000}
            """
        let stored = try JSONDecoder().decode(StoredFrameioToken.self, from: Data(legacy.utf8))
        #expect(stored == freshToken())
        let roundTrip = try JSONDecoder().decode(
            StoredFrameioToken.self, from: JSONEncoder().encode(stored))
        #expect(roundTrip == stored)
    }
}
