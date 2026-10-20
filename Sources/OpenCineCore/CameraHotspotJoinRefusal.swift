import Foundation

/// Why the platform refused a camera Wi-Fi join, in words the shared pages can show.
///
/// The platform reports some refusals with developer text ("internal error.") and a numeric
/// code. Neither belongs in operator copy: this value keeps the code in `diagnosticsCode` and
/// supplies the shared title, message and recovery actions instead.
public struct CameraHotspotJoinRefusal: Error, Hashable, Sendable, LocalizedError, CustomNSError {
    public enum Reason: Hashable, Sendable {
        /// The configuration itself was rejected, or it is not a kind a camera AP uses.
        case invalidConfiguration
        case invalidSSID
        case invalidPassphrase
        /// The operator declined the system Join prompt.
        case userDenied
        /// The platform refused its own request; a manual join in Settings can still work.
        case internalError
        /// An earlier request from this app is still pending.
        case pending
        case systemConfiguration
        case unknown
        case joinOnceNotSupported
        case alreadyAssociated
        case applicationNotInForeground
        case userUnauthorized
        case systemDenied
        /// A refusal code this build does not know.
        case other(Int)
    }

    /// The platform's refusal domain. Kept as a value so Core needs no platform framework.
    public static let platformErrorDomain = "NEHotspotConfigurationErrorDomain"

    public var reason: Reason
    /// The network as the operator knows it, for example the camera's advertised SSID.
    public var network: String
    /// The platform's raw refusal code, for the diagnostics journal only.
    public var rawCode: Int

    public init(reason: Reason, network: String, rawCode: Int? = nil) {
        self.reason = reason
        self.network = network
        self.rawCode = rawCode ?? Self.code(for: reason)
    }

    /// Maps a platform refusal code directly, for a host that already unpacked its error.
    public init(code: Int, network: String) {
        self.init(reason: Self.reason(for: code), network: network, rawCode: code)
    }

    /// Maps a platform refusal. Any other error domain returns nil and stays with its caller.
    public init?(error: NSError, network: String) {
        guard error.domain == Self.platformErrorDomain else { return nil }
        self.init(code: error.code, network: network)
    }

    /// A closed, searchable token for the journal. Never shown to the operator.
    public var diagnosticsCode: String { "error.connection.wifi-join.code\(rawCode)" }

    public var title: String { "Couldn't join the camera Wi-Fi" }

    /// Operator copy. It never contains the platform's description or raw code.
    public var message: String {
        let name = network.isEmpty ? "the camera network" : network
        switch reason {
        case .userDenied:
            return "Join the camera Wi-Fi network to continue."
        case .invalidSSID:
            return
                "The camera's Wi-Fi name looks wrong, so this device can't join it. Reconnect the camera, then try again."
        case .invalidPassphrase:
            return
                "The camera Wi-Fi key looks wrong. Pair the camera again so the app reads a fresh key."
        case .invalidConfiguration, .joinOnceNotSupported:
            return
                "The camera sent Wi-Fi details this device can't use. Reconnect the camera, then try again."
        case .alreadyAssociated:
            return "This device is already on \(name)."
        case .internalError, .pending, .systemConfiguration, .unknown, .applicationNotInForeground,
            .userUnauthorized, .systemDenied, .other:
            return
                "This device couldn't join \(name) automatically. Join it in Settings > Wi-Fi, then come back."
        }
    }

    public var actions: [RecoveryAction] {
        switch reason {
        case .userDenied, .invalidSSID, .invalidConfiguration, .joinOnceNotSupported,
            .alreadyAssociated:
            return [.retry]
        case .invalidPassphrase:
            return [.pairAgain, .retry]
        case .internalError, .pending, .systemConfiguration, .unknown, .applicationNotInForeground,
            .userUnauthorized, .systemDenied, .other:
            return [.openSettings, .retry]
        }
    }

    /// Whether another join attempt can still succeed. A decline is the operator's answer and a
    /// wrong name, key or configuration fails the same way every time, so a join loop surfaces
    /// those at once; the platform refusing its own request (internal, pending, busy) can pass
    /// on the next attempt.
    public var retryMayJoin: Bool {
        switch reason {
        case .userDenied, .invalidSSID, .invalidPassphrase, .invalidConfiguration,
            .joinOnceNotSupported, .alreadyAssociated:
            false
        case .internalError, .pending, .systemConfiguration, .unknown, .applicationNotInForeground,
            .userUnauthorized, .systemDenied, .other:
            true
        }
    }

    public var errorDescription: String? { message }

    /// The shared failure card for this refusal. The integration only supplies its identity.
    public func failure(integration: IntegrationID) -> ConnectionFailure {
        ConnectionFailure(
            reason: reason == .userDenied ? .cancelled : .joinFailed, phase: .joiningNetwork,
            title: title, message: message, actions: actions,
            code: "\(integration.rawValue).\(diagnosticsCode)")
    }

    private static func code(for reason: Reason) -> Int {
        switch reason {
        case .invalidConfiguration: 0
        case .invalidSSID: 1
        case .invalidPassphrase: 2
        case .userDenied: 7
        case .internalError: 8
        case .pending: 9
        case .systemConfiguration: 10
        case .unknown: 11
        case .joinOnceNotSupported: 12
        case .alreadyAssociated: 13
        case .applicationNotInForeground: 14
        case .userUnauthorized: 16
        case .systemDenied: 17
        case .other(let code): code
        }
    }

    /// Hosts that still inspect `NSError.domain` and `.code` see the platform's values, while
    /// `localizedDescription` stays the shared copy.
    public static var errorDomain: String { platformErrorDomain }
    public var errorCode: Int { rawCode }
    public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: message] }

    private static func reason(for code: Int) -> Reason {
        switch code {
        case 0: .invalidConfiguration
        case 1, 15: .invalidSSID
        case 2, 3: .invalidPassphrase
        case 4, 5, 6: .invalidConfiguration
        case 7: .userDenied
        case 8: .internalError
        case 9: .pending
        case 10: .systemConfiguration
        case 11: .unknown
        case 12: .joinOnceNotSupported
        case 13: .alreadyAssociated
        case 14: .applicationNotInForeground
        case 16: .userUnauthorized
        case 17: .systemDenied
        default: .other(code)
        }
    }
}
