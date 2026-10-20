import Foundation

/// A Frame.io HTTP response as seen by the portable client.
public struct FrameioHTTPResponse: Equatable, Sendable {
    public var statusCode: Int
    public var body: Data

    public init(statusCode: Int, body: Data = Data()) {
        self.statusCode = statusCode
        self.body = body
    }
}

/// Performs one HTTPS request. Every Frame.io byte (token, API, upload part) passes through
/// `send`, so the app's transport is the single place that refuses a request while the phone's
/// route belongs to a live camera (README "Network hops and camera claims").
public protocol FrameioHTTPTransport: Sendable {
    func send(_ request: FrameioAPIRequest) async throws -> FrameioHTTPResponse
}

/// App-owned credential storage. Each app keeps its own keychain or keystore namespace; this
/// product never names one, so sharing the package never shares a sign-in.
public protocol FrameioTokenStorage: Sendable {
    func load() -> StoredFrameioToken?
    func save(_ stored: StoredFrameioToken)
    func clear()
}

/// Errors from the Frame.io client and its app shells.
public enum FrameioError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case notConnected
    case http(Int, String)
    case decode(String)
    case noUploadURL
    case noProject
    case unsupportedOS
    case uploadIncomplete
    case unexpectedFileSize
    case unsafeMediaFilename

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Frame.io isn't configured (add FrameioClientID / FrameioRedirectURI via Frameio.local.xcconfig)."
        case .notConnected: "Connect Frame.io from the share options first."
        case .http(let code, let detail):
            "Frame.io request failed (HTTP \(code))\(detail.isEmpty ? "" : ": \(detail)")."
        case .decode(let detail): detail
        case .noUploadURL: "Frame.io didn't return an upload URL."
        case .noProject: "Pick a Frame.io project to upload into."
        case .unsupportedOS: "Frame.io sign-in requires iOS 17.4 or later."
        case .uploadIncomplete: "Frame.io didn't confirm the upload finished."
        case .unexpectedFileSize: "Local file size doesn't match the upload plan."
        case .unsafeMediaFilename: "The camera supplied an unsafe media filename."
        }
    }
}

/// Frame.io v4 client: token exchange and refresh, account/project listing, and the clip upload
/// workflow (create file, `PUT` each pre-signed part, poll until Frame.io confirms).
///
/// Transport, token storage, clock and the poll pause are injected; the client holds no global
/// state and performs no I/O of its own except reading the upload source file.
public struct FrameioClient: Sendable {
    public let config: FrameioConfiguration
    private let transport: any FrameioHTTPTransport
    private let tokens: any FrameioTokenStorage
    private let now: @Sendable () -> Date
    private let pause: @Sendable (Duration) async throws -> Void

    /// Frame.io assembles parts asynchronously: poll this many times, `statusPollInterval` apart.
    static let statusPollAttempts = 45
    static let statusPollInterval = Duration.seconds(2)

    public init(
        config: FrameioConfiguration,
        transport: any FrameioHTTPTransport,
        tokens: any FrameioTokenStorage,
        now: @escaping @Sendable () -> Date = { Date() },
        pause: (@Sendable (Duration) async throws -> Void)? = nil
    ) {
        self.config = config
        self.transport = transport
        self.tokens = tokens
        self.now = now
        // Resolved here, not as a closure-literal default: a public async default is copied into
        // each client and the copies can disagree on context size (swiftlang/swift#92017).
        self.pause = pause ?? { try await Task.sleep(for: $0) }
    }

    // MARK: - Auth

    /// Trades the authorization code (+ PKCE verifier) for tokens and stores them.
    @discardableResult
    public func completeSignIn(code: String, verifier: String) async throws -> FrameioToken {
        let token = try await send(
            FrameioOAuth.tokenExchangeRequest(config: config, code: code, verifier: verifier),
            as: FrameioToken.self)
        tokens.save(StoredFrameioToken(token: token, receivedAt: now()))
        return token
    }

    /// A valid access token, refreshing via the refresh token when near expiry.
    func accessToken() async throws -> String {
        guard var stored = tokens.load() else { throw FrameioError.notConnected }
        if stored.needsRefresh(at: now()), let refresh = stored.token.refreshToken {
            let refreshed = try await send(
                FrameioOAuth.refreshRequest(config: config, refreshToken: refresh),
                as: FrameioToken.self)
            // IMS may omit the refresh token on refresh; keep the one that still works.
            let token = FrameioToken(
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken ?? refresh,
                expiresIn: refreshed.expiresIn,
                tokenType: refreshed.tokenType)
            stored = StoredFrameioToken(token: token, receivedAt: now())
            tokens.save(stored)
        }
        return stored.token.accessToken
    }

    // MARK: - API

    public func currentUser() async throws -> FrameioUser {
        try await authorized(FrameioAPI.currentUser(config: config), as: FrameioOne<FrameioUser>.self)
            .data
    }

    public func accounts() async throws -> [FrameioAccount] {
        try await authorized(
            FrameioAPI.accounts(config: config), as: FrameioList<FrameioAccount>.self
        ).data
    }

    public func workspaces(accountID: String) async throws -> [FrameioWorkspace] {
        try await authorized(
            FrameioAPI.workspaces(config: config, accountID: accountID),
            as: FrameioList<FrameioWorkspace>.self
        ).data
    }

    public func projects(accountID: String, workspaceID: String) async throws -> [FrameioProject] {
        try await authorized(
            FrameioAPI.projects(config: config, accountID: accountID, workspaceID: workspaceID),
            as: FrameioList<FrameioProject>.self
        ).data
    }

    /// The projects of the first account's first workspace: the one listing every app's
    /// delivery popup offers.
    public func firstWorkspaceProjects() async throws -> FrameioProjectListing {
        guard let account = try await accounts().first else { throw FrameioError.noProject }
        guard let workspace = try await workspaces(accountID: account.id).first else {
            throw FrameioError.noProject
        }
        return FrameioProjectListing(
            accountID: account.id, workspaceID: workspace.id, workspaceName: workspace.name,
            projects: try await projects(accountID: account.id, workspaceID: workspace.id))
    }

    /// Creates a blank project in the given workspace and returns it (including its root folder).
    public func createProject(accountID: String, workspaceID: String, name: String) async throws
        -> FrameioProject
    {
        try await authorized(
            FrameioAPI.createProject(
                config: config, accountID: accountID, workspaceID: workspaceID, name: name),
            as: FrameioOne<FrameioProject>.self
        ).data
    }

    // MARK: - Upload

    /// Uploads a local file: Create File (local upload), `PUT` each chunk to its pre-signed URL,
    /// then poll until Frame.io marks the upload complete. Returns the new file id.
    ///
    /// Progress: 0.05 planned, 0.1 to 0.85 across parts, 0.85 to 0.95 while Frame.io assembles,
    /// 1.0 confirmed.
    public func upload(
        fileURL: URL, name: String, mediaType: String, fileSize: Int,
        accountID: String, folderID: String,
        progress: (@Sendable (Double) async -> Void)? = nil
    ) async throws -> String {
        let progress = progress ?? { _ in }
        await progress(0.05)
        let created = try await authorized(
            FrameioAPI.createFile(
                config: config, accountID: accountID, folderID: folderID, name: name,
                fileSize: fileSize),
            as: FrameioCreateFileResponse.self)
        let parts = created.uploadParts
        guard !parts.isEmpty else { throw FrameioError.noUploadURL }
        guard parts.reduce(0, { $0 + $1.size }) == fileSize else {
            throw FrameioError.unexpectedFileSize
        }
        let contentType = created.mediaType ?? mediaType
        await progress(0.1)

        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }

        var bytesSent = 0
        for part in parts {
            guard let uploadURL = part.uploadURL else { throw FrameioError.noUploadURL }
            let chunk = try Self.readExactBytes(count: part.size, from: fileHandle)
            // Pre-signed: no bearer token on the part upload.
            let put = FrameioAPIRequest(
                url: uploadURL, method: .put, body: chunk,
                headers: ["x-amz-acl": "private", "Content-Type": contentType])
            _ = try await checked(transport.send(put))
            bytesSent += part.size
            await progress(min(0.1 + 0.75 * Double(bytesSent) / Double(fileSize), 0.85))
        }

        try await waitForUploadComplete(
            accountID: accountID, fileID: created.fileID, progress: progress)
        await progress(1.0)
        return created.fileID
    }

    private func waitForUploadComplete(
        accountID: String, fileID: String,
        progress: @Sendable (Double) async -> Void
    ) async throws {
        let attempts = Self.statusPollAttempts
        for attempt in 0..<attempts {
            let status = try await authorized(
                FrameioAPI.uploadStatus(config: config, accountID: accountID, fileID: fileID),
                as: FrameioFileUploadStatus.self)
            if status.uploadComplete {
                await progress(0.95)
                return
            }
            await progress(0.85 + 0.1 * Double(attempt) / Double(attempts))
            try await pause(Self.statusPollInterval)
        }
        throw FrameioError.uploadIncomplete
    }

    private static func readExactBytes(count: Int, from handle: FileHandle) throws -> Data {
        var remaining = count
        var data = Data()
        data.reserveCapacity(count)
        while remaining > 0 {
            guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else {
                throw FrameioError.unexpectedFileSize
            }
            data.append(chunk)
            remaining -= chunk.count
        }
        return data
    }

    // MARK: - HTTP

    private func authorized<T: Decodable>(_ request: FrameioAPIRequest, as type: T.Type)
        async throws -> T
    {
        var request = request
        request.headers["Authorization"] = "Bearer \(try await accessToken())"
        request.headers["Accept"] = "application/json"
        return try await send(request, as: type)
    }

    private func send<T: Decodable>(_ request: FrameioAPIRequest, as type: T.Type) async throws
        -> T
    {
        let response = try await checked(transport.send(request))
        do {
            return try FrameioJSON.decode(T.self, from: response.body)
        } catch let error as FrameioDecodingError {
            throw FrameioError.decode(error.errorDescription ?? error.localizedDescription)
        }
    }

    private func checked(_ response: FrameioHTTPResponse) throws -> FrameioHTTPResponse {
        guard (200..<300).contains(response.statusCode) else {
            throw FrameioError.http(
                response.statusCode, String(decoding: response.body.prefix(500), as: UTF8.self))
        }
        return response
    }
}
