#if os(iOS)
import AuthenticationServices
import Foundation
import Observation
import OpenCineAppKit
import OpenCineAppKitApple
import OpenCineFrameIO
import Security
import UIKit

/// The app's own Frame.io namespaces. Keep each app's existing values so saved sign-ins,
/// destinations and upload history survive.
public struct FrameioHostNamespace: Sendable {
    public let keychainService: String
    public let destinationKey: String
    public let historyKey: String
    public init(keychainService: String, destinationKey: String, historyKey: String) {
        self.keychainService = keychainService
        self.destinationKey = destinationKey
        self.historyKey = historyKey
    }
}

/// The OAuth client the app registered, from its Info.plist (`FrameioClientID`,
/// `FrameioRedirectURI`, set through Frameio.local.xcconfig); nil when absent.
public enum FrameioAppConfiguration {
    public static func read(bundle: Bundle = .main) -> FrameioConfiguration? {
        guard
            let clientID = bundle.object(forInfoDictionaryKey: "FrameioClientID") as? String,
            !clientID.isEmpty,
            let redirect = bundle.object(forInfoDictionaryKey: "FrameioRedirectURI") as? String,
            !redirect.isEmpty
        else { return nil }
        return FrameioConfiguration(clientID: clientID, redirectURI: redirect)
    }
}

/// The Frame.io token in the app's keychain service. Never logs token values.
public struct FrameioKeychainTokenStore: FrameioTokenStorage {
    public let service: String
    public let account: String
    public init(service: String, account: String = "oauth-token") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func save(_ stored: StoredFrameioToken) {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    public func load() -> StoredFrameioToken? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(StoredFrameioToken.self, from: data)
    }

    public func clear() { SecItemDelete(query as CFDictionary) }
}

/// The operator's upload target under the app's defaults key.
public struct FrameioDestinationStore {
    public let key: String
    private let defaults: UserDefaults
    public init(key: String, defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
    }
    public var loaded: FrameioDestination? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(FrameioDestination.self, from: $0) }
    }
    public func persist(_ destination: FrameioDestination?) {
        if let destination, let data = try? JSONEncoder().encode(destination) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

/// Adobe IMS sign-in (PKCE) through `ASWebAuthenticationSession`, then the code exchange into
/// the supplied token storage. Native App credentials use a custom scheme
/// (`adobe+{unique}://adobeid/{clientId}`); HTTPS redirects use the iOS 17.4 `.https` callback.
@MainActor public final class FrameioWebAuthenticator: NSObject,
    ASWebAuthenticationPresentationContextProviding
{
    private let config: FrameioConfiguration
    private let transport: any FrameioHTTPTransport
    private let tokens: any FrameioTokenStorage
    private var session: ASWebAuthenticationSession?

    /// The exchange keeps `URLSession.shared` (default timeout): it runs once, right after sign-in.
    public init(
        config: FrameioConfiguration,
        transport: any FrameioHTTPTransport = FrameioURLSessionTransport(session: .shared),
        tokens: any FrameioTokenStorage
    ) {
        self.config = config
        self.transport = transport
        self.tokens = tokens
    }

    public func signIn() async throws -> FrameioToken {
        guard let redirect = URL(string: config.redirectURI) else { throw FrameioError.notConfigured }
        let pkce = PKCE.generate()
        let state = UUID().uuidString
        let callback = try await present(
            FrameioOAuth.authorizeURL(config: config, pkce: pkce, state: state), redirect: redirect)
        let code = try FrameioOAuth.parseRedirect(callback, expectedState: state)
        return try await FrameioClient(config: config, transport: transport, tokens: tokens)
            .completeSignIn(code: code, verifier: pkce.verifier)
    }

    private func present(_ url: URL, redirect: URL) async throws -> URL {
        guard #available(iOS 17.4, *) else { throw FrameioError.unsupportedOS }
        return try await withCheckedThrowingContinuation { continuation in
            // @Sendable: AuthenticationServices calls this on main today, but a closure formed
            // in this @MainActor type would trap (Swift 6 isolation check, as in
            // OPENPOCKETCINE-IOS-3P/3N) if it were ever called from another queue.
            let completion: @Sendable (URL?, Error?) -> Void = { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? FrameioError.notConnected)
                }
            }
            let callback: ASWebAuthenticationSession.Callback
            if redirect.scheme == "https" || redirect.scheme == "http" {
                guard let host = redirect.host else {
                    continuation.resume(throwing: FrameioError.notConfigured)
                    return
                }
                callback = .https(host: host, path: redirect.path.isEmpty ? "/" : redirect.path)
            } else if let scheme = redirect.scheme {
                callback = .customScheme(scheme)
            } else {
                continuation.resume(throwing: FrameioError.notConfigured)
                return
            }
            let session = ASWebAuthenticationSession(
                url: url, callback: callback, completionHandler: completion)
            session.presentationContextProvider = self
            self.session = session
            if !session.start() { continuation.resume(throwing: FrameioError.notConfigured) }
        }
    }

    nonisolated public func presentationAnchor(for session: ASWebAuthenticationSession)
        -> ASPresentationAnchor
    {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}

/// UserDefaults is documented thread-safe; this box only lets the history closures carry it.
private final class FrameioSharedDefaults: @unchecked Sendable {
    let defaults: UserDefaults
    init(_ defaults: UserDefaults) { self.defaults = defaults }
}

/// The destination one run resolved on its first upload; every later item reuses it.
@MainActor private final class FrameioCapturedDestination {
    var value: FrameioDestination?
}

/// The Frame.io account of an app: configuration, sign-in, project listing, the saved
/// destination, upload history and uploads, over the app's namespaces (A2-57).
@available(iOS 17, *) @MainActor @Observable
public final class FrameioAccountModel {
    public let configuration: FrameioConfiguration?
    @ObservationIgnored public let tokens: FrameioKeychainTokenStore
    @ObservationIgnored public let destinations: FrameioDestinationStore
    @ObservationIgnored public let history: FrameioUploadHistoryIndex
    public private(set) var user: FrameioUser?
    public private(set) var connecting = false
    /// Bumped by sign-in and sign-out so views reading the keychain state refresh.
    private var revision = 0
    @ObservationIgnored private let transport: any FrameioHTTPTransport

    public init(
        namespace: FrameioHostNamespace, configuration: FrameioConfiguration? = FrameioAppConfiguration.read(),
        defaults: UserDefaults = .standard,
        transport: any FrameioHTTPTransport = FrameioURLSessionTransport.interactive
    ) {
        self.configuration = configuration
        self.transport = transport
        tokens = FrameioKeychainTokenStore(service: namespace.keychainService)
        destinations = FrameioDestinationStore(key: namespace.destinationKey, defaults: defaults)
        let key = namespace.historyKey
        let store = FrameioSharedDefaults(defaults)
        history = FrameioUploadHistoryIndex(
            load: { store.defaults.string(forKey: key) },
            save: { value in
                store.defaults.set(value, forKey: key)
                return true
            })
    }

    public var isConfigured: Bool { configuration != nil }
    /// Configured and holding a token. A keychain token outlives app deletion, so a build
    /// without Frame.io configuration never reports one it cannot use.
    public var isConnected: Bool {
        _ = revision
        return isConfigured && tokens.load() != nil
    }

    public func client() throws -> FrameioClient {
        guard let configuration else { throw FrameioError.notConfigured }
        return FrameioClient(config: configuration, transport: transport, tokens: tokens)
    }

    public func connect() async throws {
        guard let configuration else { throw FrameioError.notConfigured }
        connecting = true
        defer {
            connecting = false
            revision += 1
        }
        _ = try await FrameioWebAuthenticator(config: configuration, tokens: tokens).signIn()
        user = try? await client().currentUser()
    }

    /// Clearing the token needs no configuration: a build can always shed a stale session.
    public func disconnect() {
        tokens.clear()
        user = nil
        destinations.persist(nil)
        revision += 1
    }

    /// Settings account actions over this account: on the camera's Wi-Fi, signing in first leaves it
    /// through the app's one internet hop and comes back afterwards (A2-23). Sign-in failures reach
    /// the settings model instead of being dropped.
    public func settingsActions<Route>(
        hop: MonitorInternetHop<Route>, route: @escaping @MainActor () -> Route?, internetFailure: String
    ) -> MonitorSettingsAccountActions {
        .overInternetHop(
            identity: ObjectIdentifier(self), isCurrent: { [weak self] in self != nil },
            connect: { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.connect()
            },
            disconnect: { [weak self] in self?.disconnect() }, hop: hop, route: route,
            internetFailure: internetFailure)
    }

    public func loadUserIfNeeded() async {
        guard isConnected, user == nil else { return }
        user = try? await client().currentUser()
    }

    /// The first workspace's projects, signing in first when needed.
    public func listing() async throws -> FrameioProjectListing {
        if !isConnected { try await connect() }
        let client = try client()
        if user == nil { user = try? await client.currentUser() }
        return try await client.firstWorkspaceProjects()
    }

    public func createProject(name: String, in listing: FrameioProjectListing) async throws
        -> FrameioProject
    {
        if !isConnected { try await connect() }
        return try await client().createProject(
            accountID: listing.accountID, workspaceID: listing.workspaceID, name: name)
    }

    public func persist(_ project: FrameioProject, in listing: FrameioProjectListing) {
        guard let destination = FrameioDestination(project: project, in: listing) else { return }
        destinations.persist(destination)
    }

    /// The one destination of an accepted run (A2-72): the project picked in the popup, else
    /// the saved destination, else the first project of the first workspace (then saved).
    public func destination(
        for project: FrameioProject?, in listing: FrameioProjectListing?
    ) async throws -> FrameioDestination {
        if let project, let listing, let picked = FrameioDestination(project: project, in: listing) {
            return picked
        }
        if let saved = destinations.loaded { return saved }
        let first = try await self.listing()
        guard let project = first.projects.first,
            let destination = FrameioDestination(project: project, in: first)
        else { throw FrameioError.noProject }
        destinations.persist(destination)
        return destination
    }

    /// Uploads one file into the run's captured destination; returns the Frame.io file id.
    @discardableResult public func upload(
        _ file: URL, name: String, to destination: FrameioDestination,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> String {
        if !isConnected { try await connect() }
        let client = try client()
        if user == nil { user = try? await client.currentUser() }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return try await client.upload(
            fileURL: file, name: name, mediaType: FrameioMediaType.forFilename(name),
            fileSize: size, accountID: destination.accountID, folderID: destination.folderID
        ) { fraction in await progress(fraction) }
    }

    /// The popup's remote service over this account. The app supplies its route facts.
    public func remoteService<Lease: Sendable>(
        onCameraNetwork: @escaping () -> Bool,
        internet: MonitorDeliveryInternetService<Lease>, transfer: @escaping (Lease) -> Lease?
    ) -> MonitorDeliveryRemoteService<FrameioProject, FrameioProjectListing, Lease> {
        .init(
            presentation: .init(displayName: "Frame.io", progressCaption: "Uploading to Frame.io"),
            observe: { [weak self] in
                let saved = self?.destinations.loaded
                return .init(
                    configured: self?.isConfigured, connected: self?.isConnected,
                    onCameraNetwork: onCameraNetwork(), savedProjectID: saved?.projectID,
                    savedProjectName: saved?.projectName)
            },
            load: { [weak self] in
                guard let self else { throw CancellationError() }
                let listing = try await self.listing()
                return .init(context: listing, projects: listing.projects.map(Self.choice))
            },
            create: { [weak self] name, listing in
                guard let self else { throw CancellationError() }
                return Self.choice(try await self.createProject(name: name, in: listing))
            },
            persist: { [weak self] project, listing in self?.persist(project.payload, in: listing) },
            internet: internet, transfer: transfer, skipsUploaded: true)
    }

    /// One accepted run's upload services: its captured destination and this account's history,
    /// keyed by the source's stable record identity.
    public func remoteRun<Record: Sendable, Curve: Sendable, Format: Sendable, Lease: Sendable>(
        request: MonitorDeliveryPreparedRequest<Curve, Format, FrameioProject, FrameioProjectListing, Lease>,
        identity: @escaping @MainActor (Record) -> String?, admission: MonitorDeliveryAdmission
    ) -> MonitorDeliveryRemoteRun<Record> {
        let history = self.history
        let captured = FrameioCapturedDestination()
        return .init(
            progressCaption: "Uploading to Frame.io",
            upload: { [weak self] _, url, progress in
                guard let self, admission.isCurrent() else { throw CancellationError() }
                if captured.value == nil {
                    captured.value = try await self.destination(
                        for: request.project?.payload, in: request.projectContext)
                }
                guard let destination = captured.value, admission.isCurrent() else {
                    throw CancellationError()
                }
                try await self.upload(url, name: url.lastPathComponent, to: destination) { fraction in
                    Task { @MainActor in if admission.isCurrent() { progress(fraction) } }
                }
            },
            history: .init(
                wasUploaded: { identity($0).map(history.wasUploaded) ?? false },
                recordUploaded: { record in _ = identity(record).map(history.recordUploaded) }),
            reupload: request.configuration?.forceReupload ?? false)
    }

    private static func choice(_ project: FrameioProject) -> MonitorDeliveryProject<FrameioProject> {
        .init(id: project.id, name: project.name, uploadable: project.rootFolderID.map { _ in true }, payload: project)
    }
}
#endif
